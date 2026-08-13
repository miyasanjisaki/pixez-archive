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
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:image/image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:mobx/mobx.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/er/prefer.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/utils/pixiv_image_identity.dart';
import 'package:pixez/utils/saucenao_result_parser.dart';
import 'package:url_launcher/url_launcher_string.dart';

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

      if (path == null && Platform.isAndroid && context != null) {
        await _showAndroidPickerChoice(context);
        if (!context.mounted) return null;
      }

      String? pickedName;
      XFile? pickedFile;
      if (path == null) {
        pickedFile = await _pickImage();
        if (pickedFile == null) {
          notStart = true;
          phase.value = SauceSearchPhase.idle;
          return null;
        }
        // XFile.name retains the Android Photo Picker display name even when
        // XFile.path points at a temporary cache copy.
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

      final inputLength = pickedFile != null
          ? await pickedFile.length()
          : await File(selectedPath).length();
      if (inputLength > _maxInputBytes) {
        _fail('Image is too large (maximum 32 MB)');
        return null;
      }
      final originImageBytes = pickedFile != null
          ? await pickedFile.readAsBytes()
          : await File(selectedPath).readAsBytes();

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

      final formData = FormData.fromMap({
        'dbs[]': '5',
        'file': MultipartFile.fromBytes(
          preparedBytes,
          filename: 'pixez_reverse_search.$preparedExtension',
        ),
      });
      final response = await dio.post<dynamic>('/search.php', data: formData);

      phase.value = SauceSearchPhase.parsing;
      BotToast.showText(text: 'SauceNAO · ${I18n.ofContext().parsing}');
      final responseHtml = switch (response.data) {
        String value => value,
        List<int> value => utf8.decode(value, allowMalformed: true),
        _ => response.data.toString(),
      };
      final ids = parseSauceNaoPixivIds(responseHtml);
      if (ids.isEmpty) {
        notStart = false;
        phase.value = SauceSearchPhase.noResult;
        final event = const SauceSearchEvent(
          illustIds: [],
          matchedLocally: false,
        );
        if (!_disposed) _streamController.add(event);
        return event;
      }
      return _finish(ids, matchedLocally: false);
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

  Future<void> _showAndroidPickerChoice(BuildContext context) async {
    final skipAlert = Prefer.getBool('photo_picker_type_selected') ?? false;
    if (skipAlert) return;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          contentPadding: const EdgeInsets.only(top: 10, bottom: 10),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Observer(
                builder: (context) {
                  return SwitchListTile(
                    secondary: const Icon(Icons.photo_album),
                    onChanged: (value) async {
                      await userSetting.setImagePickerType(value ? 1 : 0);
                    },
                    title: InkWell(
                      child: Text(I18n.of(context).photo_picker),
                      onTap: () {
                        launchUrlLauncher(
                          'https://developer.android.com/training/data-storage/shared/photopicker',
                        );
                      },
                    ),
                    subtitle: Text(I18n.of(context).photo_picker_subtitle),
                    value: userSetting.imagePickerType == 1,
                  );
                },
              ),
              const Divider(),
              InkWell(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(I18n.of(context).ok),
                  ),
                ),
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      },
    );
    await Prefer.setBool('photo_picker_type_selected', true);
  }

  Future<XFile?> _pickImage() async {
    final implementation = ImagePickerPlatform.instance;
    if (implementation is ImagePickerAndroid) {
      implementation.useAndroidPhotoPicker = userSetting.imagePickerType == 1;
    }
    return ImagePicker().pickImage(source: ImageSource.gallery);
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

  void launchUrlLauncher(String url) {
    unawaited(launchUrlString(url));
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
