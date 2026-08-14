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
import 'package:pixez/custom_tab_plugin.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/download_identity_index.dart';
import 'package:pixez/models/task_persist.dart';
import 'package:pixez/page/saucenao/iqdb_provider.dart';
import 'package:pixez/utils/pixiv_image_identity.dart';
import 'package:pixez/utils/reverse_image_search.dart';
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
  final IqdbSearchProvider _iqdbProvider = IqdbSearchProvider();
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
    _iqdbProvider.close();
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
        if (_disposed) return null;
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
      if (_disposed) return null;

      final inputLength = pickedFile != null
          ? await pickedFile.length()
          : await File(selectedPath!).length();
      if (_disposed) return null;
      if (inputLength < 0 || inputLength > _maxInputBytes) {
        _fail('Image is too large (maximum 32 MB)');
        return null;
      }
      final originImageBytes = pickedFile != null
          ? await _readPickedImage(pickedFile)
          : await File(selectedPath!).readAsBytes();
      if (_disposed) return null;
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
      if (_disposed) return null;
      if (localId != null) {
        LPrinter.d('Reverse image search resolved Pixiv ID locally: $localId');
        BotToast.showText(text: 'Pixiv ID: $localId');
        return _finish([localId], matchedLocally: true);
      }

      final fingerprints = await compute(
        computeDownloadImageFingerprints,
        originImageBytes,
      );
      if (_disposed) return null;
      final indexedIdentity = await downloadIdentityIndex.findDigest(
        fingerprints['sha256']!,
      );
      if (_disposed) return null;
      if (indexedIdentity != null) {
        localId = indexedIdentity.illustId;
        LPrinter.d(
          'Reverse image search resolved Pixiv ID by SHA-256: $localId',
        );
        BotToast.showText(text: 'Pixiv ID: $localId');
        return _finish([localId], matchedLocally: true);
      }
      final differenceHash = fingerprints['dhash'];
      if (differenceHash != null) {
        final nearDuplicate = await downloadIdentityIndex.findPerceptualHash(
          differenceHash,
          maximumDistance: 4,
          minimumDistanceGap: 3,
        );
        if (_disposed) return null;
        if (nearDuplicate != null && context != null && context.mounted) {
          final accepted = await _confirmPerceptualMatch(
            context,
            nearDuplicate,
          );
          if (_disposed || !context.mounted) return null;
          if (accepted) {
            localId = nearDuplicate.identity.illustId;
            LPrinter.d(
              'Reverse image search accepted local near duplicate: '
              '$localId (distance ${nearDuplicate.distance})',
            );
            BotToast.showText(text: 'Pixiv ID: $localId');
            return _finish([localId], matchedLocally: true);
          }
        }
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
      BotToast.showText(text: 'SauceNAO + IQDB · ${I18n.ofContext().parsing}');
      var batch = await _searchExternalProviders(
        preparedBytes,
        preparedExtension,
        ReverseImageProbeKind.full,
      );
      if (_disposed || !context.mounted) return null;

      var decision = await _resolveExternalCandidates(context, batch.hits);
      if (_disposed || !context.mounted) return null;
      var accepted = decision?.hit;
      if (accepted != null) {
        final illustId = accepted.illustId;
        if (illustId != null) {
          return _finish([illustId], matchedLocally: false);
        }
        await CustomTabPlugin.launch(accepted.sourceUrl);
        notStart = true;
        phase.value = SauceSearchPhase.idle;
        return null;
      }
      if (decision?.cancelled == true) {
        notStart = true;
        phase.value = SauceSearchPhase.idle;
        return null;
      }
      final cropRequested = decision?.retryCrop == true;

      if ((decision?.hasActionableCandidate != true || cropRequested) &&
          batch.successfulProviders > 0) {
        final crop = await _chooseCropRetry(context);
        if (_disposed || !context.mounted) return null;
        if (crop != null) {
          phase.value = SauceSearchPhase.uploading;
          BotToast.showText(text: 'Deep image search · ${crop.name}');
          final cropped = await compute(_prepareExternalSearchCrop, {
            'bytes': originImageBytes,
            'probe': crop.name,
          });
          if (cropped != null) {
            final cropBytes = cropped['bytes'] as Uint8List;
            final cropExtension = cropped['extension'] as String;
            phase.value = SauceSearchPhase.parsing;
            final cropBatch = await _searchExternalProviders(
              cropBytes,
              cropExtension,
              crop,
            );
            if (_disposed || !context.mounted) return null;
            batch = batch.merge(cropBatch);
            decision = await _resolveExternalCandidates(
              context,
              batch.hits,
              allowCropRetry: false,
            );
            if (_disposed || !context.mounted) return null;
            accepted = decision?.hit;
            if (accepted != null) {
              final illustId = accepted.illustId;
              if (illustId != null) {
                return _finish([illustId], matchedLocally: false);
              }
              await CustomTabPlugin.launch(accepted.sourceUrl);
              notStart = true;
              phase.value = SauceSearchPhase.idle;
              return null;
            }
            if (decision?.cancelled == true) {
              notStart = true;
              phase.value = SauceSearchPhase.idle;
              return null;
            }
          }
        }
      }

      if (batch.successfulProviders == 0 && batch.serviceMessages.isNotEmpty) {
        _fail(batch.serviceMessages.join('\n'));
        return null;
      }
      if (batch.serviceMessages.isNotEmpty) {
        final isChinese = Localizations.localeOf(context).languageCode == 'zh';
        lastError.value = isChinese
            ? '未找到匹配；部分识图服务不可用：\n${batch.serviceMessages.join('\n')}'
            : 'No match found; some providers were unavailable:\n'
                  '${batch.serviceMessages.join('\n')}';
      }
      notStart = false;
      phase.value = SauceSearchPhase.noResult;
      final event = const SauceSearchEvent(
        illustIds: [],
        matchedLocally: false,
      );
      if (!_disposed) _streamController.add(event);
      return event;
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

  Future<_ExternalSearchBatch> _searchExternalProviders(
    Uint8List bytes,
    String extension,
    ReverseImageProbeKind probe,
  ) async {
    final hits = <ReverseImageProviderHit>[];
    final messages = <String>[];
    var successfulProviders = 0;

    SauceNaoPixivResults? sauceResults;
    try {
      sauceResults = await _searchSauceNao(bytes, extension, pixivOnly: true);
      successfulProviders++;
    } on SauceNaoResponseException catch (error) {
      messages.add(error.message);
      LPrinter.d('SauceNAO provider unavailable: ${error.message}');
    } on DioException catch (error) {
      final message = _dioMessage(error);
      messages.add(message);
      LPrinter.d('SauceNAO provider unavailable: $message');
    } catch (error, stackTrace) {
      const message = 'SauceNAO returned an unsupported response';
      messages.add(message);
      LPrinter.d('$message: $error\n$stackTrace');
    }

    if (sauceResults != null && sauceResults.exactMatches.isEmpty) {
      LPrinter.d(
        'SauceNAO db5 returned no high-confidence Pixiv candidate; '
        'trying db999',
      );
      try {
        final allDatabaseResults = await _searchSauceNao(
          bytes,
          extension,
          pixivOnly: false,
        );
        sauceResults = _mergeSauceResults(sauceResults, allDatabaseResults);
      } on SauceNaoResponseException catch (error) {
        // Keep the valid Pixiv-index candidates. A failed broad fallback is a
        // partial provider failure, not a reason to discard earlier evidence.
        messages.add(error.message);
        LPrinter.d(
          'SauceNAO all-database fallback unavailable: ${error.message}',
        );
      } on DioException catch (error) {
        final message = _dioMessage(error);
        messages.add(message);
        LPrinter.d('SauceNAO all-database fallback unavailable: $message');
      } catch (error, stackTrace) {
        const message = 'SauceNAO all-database response was unsupported';
        messages.add(message);
        LPrinter.d('$message: $error\n$stackTrace');
      }
    }

    if (sauceResults != null) {
      for (final candidate in [
        ...sauceResults.exactMatches,
        ...sauceResults.possibleMatches,
      ]) {
        hits.add(
          ReverseImageProviderHit(
            providerId: 'saucenao',
            probe: probe,
            illustId: candidate.illustId,
            similarity: candidate.similarity,
            sourceUrl: candidate.pixivUrl,
            title: 'Pixiv #${candidate.illustId}',
          ),
        );
      }
      for (final candidate in sauceResults.externalMatches) {
        hits.add(
          ReverseImageProviderHit(
            providerId: 'saucenao',
            probe: probe,
            illustId: null,
            similarity: candidate.similarity,
            sourceUrl: candidate.sourceUrl,
            title: candidate.title,
          ),
        );
      }
    }

    try {
      final iqdbResponse = await _iqdbProvider.search(
        ReverseImageQuery(bytes: bytes, extension: extension, probe: probe),
      );
      if (iqdbResponse.serviceMessage == null) {
        successfulProviders++;
      } else {
        messages.add(iqdbResponse.serviceMessage!);
        LPrinter.d(
          'IQDB provider unavailable: ${iqdbResponse.serviceMessage}',
        );
      }
      hits.addAll(iqdbResponse.hits);
    } catch (error, stackTrace) {
      const message = 'IQDB returned an unsupported response';
      messages.add(message);
      LPrinter.d('$message: $error\n$stackTrace');
    }

    return _ExternalSearchBatch(
      // Preserve independent provider evidence here. Candidate presentation
      // is deduplicated later, after agreement has contributed to ranking.
      hits: List.unmodifiable(hits),
      successfulProviders: successfulProviders,
      serviceMessages: messages,
    );
  }

  SauceNaoPixivResults _mergeSauceResults(
    SauceNaoPixivResults first,
    SauceNaoPixivResults second,
  ) {
    return SauceNaoPixivResults(
      exactMatches: <SauceNaoPixivCandidate>[
        ...first.exactMatches,
        ...second.exactMatches,
      ],
      possibleMatches: <SauceNaoPixivCandidate>[
        ...first.possibleMatches,
        ...second.possibleMatches,
      ],
      externalMatches: <SauceNaoExternalCandidate>[
        ...first.externalMatches,
        ...second.externalMatches,
      ],
    );
  }

  List<ReverseImageProviderHit> _deduplicateProviderHits(
    Iterable<ReverseImageProviderHit> hits,
  ) {
    final best = <String, ReverseImageProviderHit>{};
    for (final hit in hits) {
      final key = hit.illustId == null
          ? 'url:${hit.sourceUrl}'
          : 'pixiv:${hit.illustId}';
      final previous = best[key];
      if (previous == null || previous.similarity < hit.similarity) {
        best[key] = hit;
      }
    }
    return best.values.toList(growable: false)
      ..sort((a, b) => b.similarity.compareTo(a.similarity));
  }

  Future<_ExternalCandidateDecision?> _resolveExternalCandidates(
    BuildContext context,
    List<ReverseImageProviderHit> hits, {
    bool allowCropRetry = true,
  }) async {
    if (hits.isEmpty) {
      return const _ExternalCandidateDecision.noActionableCandidate();
    }
    final pixivCandidates = aggregateReverseImageHits(hits);
    double? strongestExternalSimilarity;
    for (final hit in hits) {
      if (hit.illustId != null) continue;
      if (strongestExternalSimilarity == null ||
          hit.similarity > strongestExternalSimilarity) {
        strongestExternalSimilarity = hit.similarity;
      }
    }
    final autoCandidate = chooseReverseImageAutoOpenCandidate(
      pixivCandidates,
      strongestExternalSimilarity: strongestExternalSimilarity,
    );
    if (autoCandidate != null) {
      return _ExternalCandidateDecision.select(autoCandidate.evidence.first);
    }

    final pixivRankById = <int, double>{
      for (final candidate in pixivCandidates)
        candidate.illustId: candidate.rankScore,
    };
    final retainedPixivIds = pixivRankById.keys.toSet();
    final candidates =
        _deduplicateProviderHits(
          hits.where(
            (hit) =>
                hit.illustId == null || retainedPixivIds.contains(hit.illustId),
          ),
        )..sort((left, right) {
          final leftScore = left.illustId == null
              ? left.similarity
              : pixivRankById[left.illustId] ?? left.similarity;
          final rightScore = right.illustId == null
              ? right.similarity
              : pixivRankById[right.illustId] ?? right.similarity;
          return rightScore.compareTo(leftScore);
        });
    final visibleCandidates = candidates.take(5).toList(growable: false);
    if (visibleCandidates.isEmpty) {
      return const _ExternalCandidateDecision.noActionableCandidate();
    }
    final isChinese = Localizations.localeOf(context).languageCode == 'zh';
    final title = isChinese ? '找到可能的来源' : 'Possible image sources';
    final message = isChinese
        ? '这些是相似候选，不保证就是原作。Pixiv 候选会在应用内打开，其他来源会在浏览器打开。'
        : 'These are similarity candidates, not guaranteed originals. Pixiv '
              'opens in the app; other sources open in the browser.';

    String candidateHost(ReverseImageProviderHit candidate) =>
        Uri.tryParse(candidate.sourceUrl)?.host ?? candidate.sourceUrl;

    String candidateLabel(ReverseImageProviderHit candidate) {
      final host = candidateHost(candidate);
      return candidate.illustId == null
          ? (candidate.title?.trim().isNotEmpty == true
                ? candidate.title!
                : host)
          : 'Pixiv #${candidate.illustId}';
    }

    String candidateSubtitle(ReverseImageProviderHit candidate) =>
        '${candidate.providerId.toUpperCase()} · '
        '${candidate.similarity.toStringAsFixed(1)}% · '
        '${candidateHost(candidate)}';

    Widget materialCandidateTile(
      BuildContext dialogContext,
      ReverseImageProviderHit candidate,
    ) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          candidateLabel(candidate),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(candidateSubtitle(candidate)),
        trailing: Icon(
          candidate.illustId == null ? Icons.open_in_new : Icons.image_search,
        ),
        onTap: () => Navigator.of(
          dialogContext,
        ).pop(_ExternalCandidateDecision.select(candidate)),
      );
    }

    Widget fluentCandidateTile(
      BuildContext dialogContext,
      ReverseImageProviderHit candidate,
    ) => fluent.ListTile(
      title: Text(
        candidateLabel(candidate),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(candidateSubtitle(candidate)),
      onPressed: () => Navigator.of(
        dialogContext,
      ).pop(_ExternalCandidateDecision.select(candidate)),
    );

    if (Platform.isWindows) {
      return await fluent.showDialog<_ExternalCandidateDecision>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => fluent.ContentDialog(
              title: Text(title),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(message),
                      const SizedBox(height: 8),
                      ...visibleCandidates.map(
                        (candidate) =>
                            fluentCandidateTile(dialogContext, candidate),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                if (allowCropRetry)
                  fluent.Button(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(const _ExternalCandidateDecision.retryCrop()),
                    child: Text(isChinese ? '区域重试' : 'Try a crop'),
                  ),
                fluent.Button(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(I18n.of(dialogContext).cancel),
                ),
              ],
            ),
          ) ??
          const _ExternalCandidateDecision.cancelled();
    }
    return await showDialog<_ExternalCandidateDecision>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(message),
                    const SizedBox(height: 8),
                    ...visibleCandidates.map(
                      (candidate) =>
                          materialCandidateTile(dialogContext, candidate),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              if (allowCropRetry)
                TextButton(
                  onPressed: () => Navigator.of(
                    dialogContext,
                  ).pop(const _ExternalCandidateDecision.retryCrop()),
                  child: Text(isChinese ? '区域重试' : 'Try a crop'),
                ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(I18n.of(dialogContext).cancel),
              ),
            ],
          ),
        ) ??
        const _ExternalCandidateDecision.cancelled();
  }

  Future<ReverseImageProbeKind?> _chooseCropRetry(BuildContext context) async {
    final isChinese = Localizations.localeOf(context).languageCode == 'zh';
    final title = isChinese ? '尝试区域识图？' : 'Retry with one region?';
    final message = isChinese
        ? '全图没有找到候选。你可以选择一个保留主体的区域，再向 SauceNAO 和 IQDB 各提交一次去除元数据的裁剪副本。'
        : 'No full-image candidate was found. Choose one subject region to '
              'submit one metadata-free crop to SauceNAO and IQDB.';
    const options = [
      ReverseImageProbeKind.center,
      ReverseImageProbeKind.left,
      ReverseImageProbeKind.right,
      ReverseImageProbeKind.top,
      ReverseImageProbeKind.bottom,
    ];
    String label(ReverseImageProbeKind value) {
      if (!isChinese) return value.name;
      return switch (value) {
        ReverseImageProbeKind.center => '中央',
        ReverseImageProbeKind.left => '左侧',
        ReverseImageProbeKind.right => '右侧',
        ReverseImageProbeKind.top => '上方',
        ReverseImageProbeKind.bottom => '下方',
        ReverseImageProbeKind.full => '全图',
      };
    }

    if (Platform.isWindows) {
      return fluent.showDialog<ReverseImageProbeKind>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => fluent.ContentDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(message),
              const SizedBox(height: 8),
              ...options.map(
                (option) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: fluent.Button(
                    onPressed: () => Navigator.of(dialogContext).pop(option),
                    child: Text(label(option)),
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
      );
    }
    return showDialog<ReverseImageProbeKind>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(message),
              const SizedBox(height: 8),
              ...options.map(
                (option) => ListTile(
                  title: Text(label(option)),
                  trailing: const Icon(Icons.crop),
                  onTap: () => Navigator.of(dialogContext).pop(option),
                ),
              ),
            ],
          ),
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

  Future<bool> _confirmPerceptualMatch(
    BuildContext context,
    DownloadPerceptualIdentityMatch match,
  ) async {
    final isChinese = Localizations.localeOf(context).languageCode == 'zh';
    final percent = (match.similarity * 100).toStringAsFixed(1);
    final title = isChinese ? '发现本地近似图片' : 'Local near-duplicate found';
    final message = isChinese
        ? '这张图与本机已索引的 Pixiv #${match.identity.illustId} '
              '在缩放/重新压缩特征上约为 $percent% 相似。'
              '感知哈希不能证明原作，是否打开该作品？'
        : 'This image is about $percent% similar to locally indexed Pixiv '
              '#${match.identity.illustId} after resize/re-encode matching. '
              'A perceptual hash is not proof of authorship. Open it?';

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
    final event = SauceSearchEvent(
      illustIds: unique,
      matchedLocally: matchedLocally,
    );
    if (_disposed) return event;
    results
      ..clear()
      ..addAll(unique);
    notStart = false;
    phase.value = SauceSearchPhase.success;
    _streamController.add(event);
    return event;
  }

  void _fail(String message) {
    if (_disposed) return;
    notStart = false;
    lastError.value = message;
    phase.value = SauceSearchPhase.error;
    BotToast.showText(text: message);
  }

  String _dioMessage(DioException error) {
    final status = error.response?.statusCode;
    if (status == 429) return 'SauceNAO: too many requests (429)';
    if (status == 403) {
      return 'SauceNAO: browser verification required (403)';
    }
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

Map<String, Object>? _prepareExternalSearchCrop(Map<String, Object> request) {
  final bytes = request['bytes'];
  final probeName = request['probe'];
  if (bytes is! Uint8List || probeName is! String) return null;
  if (bytes.length > SauceStoreBase._maxInputBytes) return null;
  ReverseImageProbeKind? probe;
  for (final value in ReverseImageProbeKind.values) {
    if (value.name == probeName) {
      probe = value;
      break;
    }
  }
  if (probe == null || probe == ReverseImageProbeKind.full) return null;

  final decoder = findDecoderForData(bytes);
  if (decoder == null) return null;
  final info = decoder.startDecode(bytes);
  if (info == null || info.width <= 0 || info.height <= 0) return null;
  if (info.width * info.height > SauceStoreBase._maxDecodedPixels) return null;
  final image = decoder.decodeFrame(0);
  if (image == null) return null;

  final region = planReverseImageProbeRegions(
    image.width,
    image.height,
  ).singleWhere((region) => region.kind == probe);
  var cropped = copyCrop(
    image,
    x: region.x,
    y: region.y,
    width: region.width,
    height: region.height,
  );
  final longestSide = cropped.width > cropped.height
      ? cropped.width
      : cropped.height;
  if (longestSide > SauceStoreBase._maxSearchDimension) {
    cropped = copyResize(
      cropped,
      width: (cropped.width * SauceStoreBase._maxSearchDimension / longestSide)
          .round(),
      height:
          (cropped.height * SauceStoreBase._maxSearchDimension / longestSide)
              .round(),
    );
  }
  cropped.exif = ExifData();
  cropped.iccProfile = null;
  cropped.textData = null;
  return {'bytes': encodeJpg(cropped, quality: 90), 'extension': 'jpg'};
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

class _ExternalCandidateDecision {
  final ReverseImageProviderHit? hit;
  final bool retryCrop;
  final bool cancelled;
  final bool hasActionableCandidate;

  const _ExternalCandidateDecision.select(ReverseImageProviderHit selected)
    : hit = selected,
      retryCrop = false,
      cancelled = false,
      hasActionableCandidate = true;

  const _ExternalCandidateDecision.retryCrop()
    : hit = null,
      retryCrop = true,
      cancelled = false,
      hasActionableCandidate = true;

  const _ExternalCandidateDecision.cancelled()
    : hit = null,
      retryCrop = false,
      cancelled = true,
      hasActionableCandidate = true;

  const _ExternalCandidateDecision.noActionableCandidate()
    : hit = null,
      retryCrop = false,
      cancelled = false,
      hasActionableCandidate = false;
}

class _ExternalSearchBatch {
  final List<ReverseImageProviderHit> hits;
  final int successfulProviders;
  final List<String> serviceMessages;

  const _ExternalSearchBatch({
    required this.hits,
    required this.successfulProviders,
    required this.serviceMessages,
  });

  _ExternalSearchBatch merge(_ExternalSearchBatch other) {
    return _ExternalSearchBatch(
      // Keep probe/provider evidence separate. The dialog performs its own
      // URL/Pixiv deduplication after aggregate ranking has been calculated.
      hits: List.unmodifiable(<ReverseImageProviderHit>[
        ...hits,
        ...other.hits,
      ]),
      successfulProviders: successfulProviders + other.successfulProviders,
      serviceMessages: {...serviceMessages, ...other.serviceMessages}.toList(),
    );
  }
}
