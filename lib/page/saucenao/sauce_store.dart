/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bot_toast/bot_toast.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart';
import 'package:mobx/mobx.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/download_identity_index.dart';
import 'package:pixez/models/task_persist.dart';
import 'package:pixez/utils/pixiv_image_identity.dart';
import 'package:pixez/utils/saucenao_result_parser.dart';

part 'sauce_store.g.dart';

enum SauceSearchPhase {
  idle,
  picking,
  inspecting,
  uploading,
  parsing,
  success,
  noResult,
  error,
}

extension SauceSearchPhaseState on SauceSearchPhase {
  bool get isBusy =>
      this == SauceSearchPhase.picking ||
      this == SauceSearchPhase.inspecting ||
      this == SauceSearchPhase.uploading ||
      this == SauceSearchPhase.parsing;
}

class SauceSearchEvent {
  final List<int> illustIds;
  final bool matchedLocally;

  const SauceSearchEvent({
    required this.illustIds,
    required this.matchedLocally,
  });
}

class SauceStore = SauceStoreBase with _$SauceStore;

abstract class SauceStoreBase with Store {
  static const String host = 'saucenao.com';
  static const int _maxInputBytes = 32 * 1024 * 1024;
  static const int _maxSearchDimension = 1600;
  static const int _maxDecodedPixels = 32 * 1024 * 1024;

  final Dio dio = Dio(
    BaseOptions(
      baseUrl: 'https://saucenao.com',
      connectTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 45),
      receiveTimeout: const Duration(seconds: 45),
      followRedirects: true,
      headers: const {
        'Accept': 'text/html,application/xhtml+xml',
        'User-Agent': 'PixEz-Archive reverse-image-search',
      },
    ),
  );

  final ObservableList<int> results = ObservableList<int>();
  final Observable<SauceSearchPhase> phase = Observable(SauceSearchPhase.idle);
  final Observable<String?> lastError = Observable(null);
  final StreamController<SauceSearchEvent> _streamController =
      StreamController<SauceSearchEvent>.broadcast(sync: true);

  Stream<SauceSearchEvent> get observableStream => _streamController.stream;

  @observable
  bool notStart = true;

  bool _disposed = false;
  bool _requestInProgress = false;

  void dispose() {
    _disposed = true;
    dio.close(force: true);
    unawaited(_streamController.close());
  }

  Future<SauceSearchEvent?> findImage({
    BuildContext? context,
    String? path,
    bool retry = false,
  }) async {
    if (_disposed || _requestInProgress) return null;
    _requestInProgress = true;

    try {
      results.clear();
      lastError.value = null;
      phase.value = path == null
          ? SauceSearchPhase.picking
          : SauceSearchPhase.inspecting;

      String? pickedName;
      PlatformFile? pickedFile;
      if (path == null) {
        pickedFile = await _pickImage();
        if (pickedFile == null) {
          notStart = true;
          phase.value = SauceSearchPhase.idle;
          return null;
        }
        // PlatformFile.name is the provider DISPLAY_NAME. Do not infer image
        // identity from its temporary cache path on Android.
        pickedName = pickedFile.name;
        path = pickedFile.path;
        phase.value = SauceSearchPhase.inspecting;
      } else {
        pickedName = _lastPathSegment(path);
      }
      final selectedPath = path;
      notStart = false;

      var localId = extractPixivIllustId(hints: [pickedName, selectedPath]);
      if (localId != null) {
        LPrinter.d('Reverse image search resolved Pixiv ID locally: $localId');
        BotToast.showText(text: 'Pixiv ID: $localId');
        return _finish([localId], matchedLocally: true);
      }

      // Completed task rows predate the content-hash index. Treat a unique
      // filename match only as a user-confirmed hint after stronger exact
      // identity checks; never persist the selected bytes under that hint.
      final completedTask = pickedName == null
          ? null
          : await _completedTaskForName(pickedName);

      final inputLength = pickedFile != null
          ? await pickedFile.length()
          : await File(selectedPath!).length();
      if (inputLength < 0 || inputLength > _maxInputBytes) {
        _fail('Image is too large (maximum 32 MB)');
        return null;
      }
      final originImageBytes = pickedFile != null
          ? await _readPickedImage(pickedFile)
          : await File(selectedPath!).readAsBytes();
      // Some document providers cannot report a size before the file is read.
      if (originImageBytes == null ||
          originImageBytes.length > _maxInputBytes) {
        _fail('Image is too large (maximum 32 MB)');
        return null;
      }

      BotToast.showText(text: I18n.ofContext().parsing);
      localId ??= await compute(
        extractPixivIllustIdFromBytes,
        originImageBytes,
      );
      if (localId != null) {
        LPrinter.d('Reverse image search resolved Pixiv ID locally: $localId');
        BotToast.showText(text: 'Pixiv ID: $localId');
        return _finish([localId], matchedLocally: true);
      }

      final digest = await compute(computeImageSha256, originImageBytes);
      final indexedIdentity = await downloadIdentityIndex.findDigest(digest);
      if (indexedIdentity != null) {
        localId = indexedIdentity.illustId;
        LPrinter.d(
          'Reverse image search resolved Pixiv ID by SHA-256: $localId',
        );
        BotToast.showText(text: 'Pixiv ID: $localId');
        return _finish([localId], matchedLocally: true);
      }
      if (completedTask != null) {
        // Old task rows only prove that PixEz once saved a file with this
        // name. The gallery file may since have been replaced or edited, so a
        // name match is never promoted into the exact-byte SHA index.
        if (context != null && context.mounted) {
          final accepted = await _confirmHistoricalDownload(
            context,
            completedTask,
          );
          if (_disposed || !context.mounted) return null;
          if (accepted) {
            localId = completedTask.illustId;
            LPrinter.d(
              'Reverse image search accepted historical download: $localId',
            );
            BotToast.showText(text: 'Pixiv ID: $localId');
            return _finish([localId], matchedLocally: true);
          }
        }
      }

      if (context == null || !context.mounted) {
        _fail('External image search requires confirmation');
        return null;
      }
      final uploadConfirmed = await _confirmExternalUpload(context);
      if (_disposed || !context.mounted) return null;
      if (!uploadConfirmed) {
        notStart = true;
        phase.value = SauceSearchPhase.idle;
        return null;
      }

      phase.value = SauceSearchPhase.uploading;
      BotToast.showText(text: 'SauceNAO · ${I18n.ofContext().uploading}');
      final prepared = await compute(
        _prepareExternalSearchImage,
        originImageBytes,
      );
      if (prepared == null) {
        _fail('Image is too large or unsupported');
        return null;
      }
      final preparedBytes = prepared['bytes'] as Uint8List;
      final preparedExtension = prepared['extension'] as String;
      LPrinter.d(
        'Reverse image upload size: ${originImageBytes.length} -> '
        '${preparedBytes.length}',
      );

      phase.value = SauceSearchPhase.parsing;
      BotToast.showText(text: 'SauceNAO · ${I18n.ofContext().parsing}');
      var parsed = await _searchSauceNao(
        preparedBytes,
        preparedExtension,
        pixivOnly: true,
      );
      if (parsed.isEmpty) {
        // One controlled fallback lets mirror/booru cards contribute only
        // when they contain an explicit Pixiv or pximg source link.
        LPrinter.d('SauceNAO db5 returned no Pixiv candidate; trying db999');
        parsed = await _searchSauceNao(
          preparedBytes,
          preparedExtension,
          pixivOnly: false,
        );
      }

      if (parsed.exactMatches.isNotEmpty) {
        return _finish([
          parsed.exactMatches.first.illustId,
        ], matchedLocally: false);
      }
      if (parsed.possibleMatches.isNotEmpty) {
        if (!context.mounted) return null;
        final accepted = await _confirmPossibleMatches(
          context,
          parsed.possibleMatches.take(3).toList(growable: false),
        );
        if (_disposed || !context.mounted) return null;
        if (accepted != null) {
          return _finish([accepted.illustId], matchedLocally: false);
        }
        // The user saw a real possible match and declined it. Returning to
        // idle avoids misreporting that interaction as "0 results".
        notStart = true;
        phase.value = SauceSearchPhase.idle;
        return null;
      }

      if (parsed.isEmpty) {
        notStart = false;
        phase.value = SauceSearchPhase.noResult;
        final event = const SauceSearchEvent(
          illustIds: [],
          matchedLocally: false,
        );
        if (!_disposed) _streamController.add(event);
        return event;
      }
      return null;
    } on SauceNaoResponseException catch (error) {
      _fail(error.message);
      return null;
    } on DioException catch (error) {
      _fail(_dioMessage(error));
      return null;
    } catch (error, stackTrace) {
      LPrinter.d('Reverse image search failed: $error\n$stackTrace');
      _fail('Reverse image search failed');
      return null;
    } finally {
      _requestInProgress = false;
    }
  }

  Future<TaskPersist?> _completedTaskForName(String fileName) async {
    try {
      return await fetcher.taskPersistProvider.getCompletedByFileName(fileName);
    } catch (error, stackTrace) {
      LPrinter.d('Historical download lookup failed: $error');
      LPrinter.d(stackTrace);
      return null;
    }
  }

  Future<PlatformFile?> _pickImage() {
    return FilePicker.pickFile(type: FileType.image);
  }

  Future<Uint8List?> _readPickedImage(PlatformFile file) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in file.readAsByteStream()) {
      length += chunk.length;
      if (length > _maxInputBytes) return null;
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<SauceNaoPixivResults> _searchSauceNao(
    Uint8List bytes,
    String extension, {
    required bool pixivOnly,
  }) async {
    final form = <String, dynamic>{
      if (pixivOnly) 'dbs[]': '5' else 'db': '999',
      'file': MultipartFile.fromBytes(
        bytes,
        filename: 'pixez_reverse_search.$extension',
      ),
    };
    final response = await dio.post<dynamic>(
      '/search.php',
      data: FormData.fromMap(form),
    );
    final responseHtml = switch (response.data) {
      String value => value,
      List<int> value => utf8.decode(value, allowMalformed: true),
      _ => response.data.toString(),
    };
    return parseSauceNaoPixivResults(responseHtml);
  }

  Future<SauceNaoPixivCandidate?> _confirmPossibleMatches(
    BuildContext context,
    List<SauceNaoPixivCandidate> candidates,
  ) async {
    final isChinese = Localizations.localeOf(context).languageCode == 'zh';
    final title = isChinese ? '可能的 Pixiv 匹配' : 'Possible Pixiv match';
    final message = isChinese
        ? '相似度未达到自动打开阈值，请选择要打开的候选结果。'
        : 'Similarity is below the automatic threshold. Choose a candidate.';

    return Platform.isWindows
        ? await fluent.showDialog<SauceNaoPixivCandidate>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => fluent.ContentDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(message),
                  const SizedBox(height: 12),
                  ...candidates.map(
                    (candidate) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: fluent.Button(
                        onPressed: () =>
                            Navigator.of(dialogContext).pop(candidate),
                        child: Text(
                          'Pixiv #${candidate.illustId} · '
                          '${candidate.similarity.toStringAsFixed(1)}%',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                fluent.Button(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(I18n.of(dialogContext).cancel),
                ),
              ],
            ),
          )
        : await showDialog<SauceNaoPixivCandidate>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(message),
                  const SizedBox(height: 8),
                  ...candidates.map(
                    (candidate) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Pixiv #${candidate.illustId}'),
                      subtitle: Text(
                        '${candidate.similarity.toStringAsFixed(1)}%',
                      ),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () => Navigator.of(dialogContext).pop(candidate),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(I18n.of(dialogContext).cancel),
                ),
              ],
            ),
          );
  }

  Future<bool> _confirmHistoricalDownload(
    BuildContext context,
    TaskPersist task,
  ) async {
    final isChinese = Localizations.localeOf(context).languageCode == 'zh';
    final title = isChinese ? '发现历史下载记录' : 'Historical download found';
    final message = isChinese
        ? '文件名与过去下载的「${task.title}」（Pixiv #${task.illustId}）相同，'
              '但无法确认图片内容是否被替换或编辑。是否打开该作品？'
        : 'The file name matches a previous download, "${task.title}" '
              '(Pixiv #${task.illustId}), but the image bytes cannot be '
              'verified. Open this work?';

    if (Platform.isWindows) {
      return await fluent.showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => fluent.ContentDialog(
              title: Text(title),
              content: Text(message),
              actions: [
                fluent.Button(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(I18n.of(dialogContext).cancel),
                ),
                fluent.FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(I18n.of(dialogContext).ok),
                ),
              ],
            ),
          ) ??
          false;
    }

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(I18n.of(dialogContext).cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(I18n.of(dialogContext).ok),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _confirmExternalUpload(BuildContext context) async {
    final title = I18n.of(context).reverse_image_external_title;
    final message = I18n.of(context).reverse_image_external_message;
    if (Platform.isWindows) {
      return await fluent.showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => fluent.ContentDialog(
              title: Text(title),
              content: Text(message),
              actions: [
                fluent.Button(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(I18n.of(dialogContext).cancel),
                ),
                fluent.FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(I18n.of(dialogContext).ok),
                ),
              ],
            ),
          ) ??
          false;
    }

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(I18n.of(dialogContext).cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(I18n.of(dialogContext).ok),
              ),
            ],
          ),
        ) ??
        false;
  }

  SauceSearchEvent _finish(Iterable<int> ids, {required bool matchedLocally}) {
    final unique = <int>{...ids}.toList(growable: false);
    results
      ..clear()
      ..addAll(unique);
    notStart = false;
    phase.value = SauceSearchPhase.success;
    final event = SauceSearchEvent(
      illustIds: unique,
      matchedLocally: matchedLocally,
    );
    if (!_disposed) _streamController.add(event);
    return event;
  }

  void _fail(String message) {
    notStart = false;
    lastError.value = message;
    phase.value = SauceSearchPhase.error;
    BotToast.showText(text: message);
  }

  String _dioMessage(DioException error) {
    final status = error.response?.statusCode;
    if (status == 429) return 'SauceNAO: too many requests (429)';
    if (status != null) return 'SauceNAO: request failed ($status)';
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return 'SauceNAO: timeout';
    }
    return 'SauceNAO: network error';
  }

  String _lastPathSegment(String path) {
    final uri = Uri.tryParse(path);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
    return path.split(RegExp(r'[/\\]')).last;
  }
}

Map<String, Object>? _prepareExternalSearchImage(Uint8List originImageBytes) {
  if (originImageBytes.length > SauceStoreBase._maxInputBytes) return null;
  final extension = _detectImageExtension(originImageBytes);
  if (extension == null) return null;

  final decoder = findDecoderForData(originImageBytes);
  if (decoder == null) return null;
  final info = decoder.startDecode(originImageBytes);
  if (info == null || info.width <= 0 || info.height <= 0) return null;
  final pixels = info.width * info.height;
  if (pixels > SauceStoreBase._maxDecodedPixels) return null;
  final longestSide = info.width > info.height ? info.width : info.height;
  final originImage = decoder.decodeFrame(0);
  if (originImage == null) return null;
  final resized = longestSide <= SauceStoreBase._maxSearchDimension
      ? originImage
      : copyResize(
          originImage,
          width:
              (originImage.width *
                      SauceStoreBase._maxSearchDimension /
                      longestSide)
                  .round(),
          height:
              (originImage.height *
                      SauceStoreBase._maxSearchDimension /
                      longestSide)
                  .round(),
        );
  // Always re-encode the external-search copy. This strips EXIF/text metadata
  // and prevents an original gallery file from being sent to a third party.
  resized.exif = ExifData();
  resized.iccProfile = null;
  resized.textData = null;
  return {'bytes': encodeJpg(resized, quality: 90), 'extension': 'jpg'};
}

String? _detectImageExtension(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'jpg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 6 &&
      ascii.decode(bytes.sublist(0, 3), allowInvalid: true) == 'GIF') {
    return 'gif';
  }
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return 'webp';
  }
  return null;
}
