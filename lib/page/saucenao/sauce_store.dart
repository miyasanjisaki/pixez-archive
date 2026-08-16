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
import 'package:pixez/network/external_search_failure.dart';
import 'package:pixez/network/external_search_transport.dart';
import 'package:pixez/page/saucenao/bookmark_visual_search_dialog.dart';
import 'package:pixez/page/saucenao/iqdb_provider.dart';
import 'package:pixez/page/webview/ascii2d_browser_search_page.dart';
import 'package:pixez/utils/bookmark_visual_search.dart';
import 'package:pixez/utils/pixiv_bookmark_visual_search.dart';
import 'package:pixez/utils/pixiv_image_identity.dart';
import 'package:pixez/utils/reverse_image_search.dart';
import 'package:pixez/utils/reverse_image_session.dart';
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
  cancelled,
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

  final ExternalSearchDioClient _sauceDioClient = ExternalSearchDioClient(
    baseUrl: 'https://saucenao.com',
    networkModeProvider: () => userSetting.networkMode,
  );

  final ObservableList<int> results = ObservableList<int>();
  final IqdbSearchProvider _iqdbProvider = IqdbSearchProvider(
    networkModeProvider: () => userSetting.networkMode,
  );
  final Observable<SauceSearchPhase> phase = Observable(SauceSearchPhase.idle);
  final Observable<String?> lastError = Observable(null);
  final Observable<String?> selectedFileName = Observable(null);
  final Observable<Uint8List?> selectedImageBytes = Observable(null);
  final Observable<bool> searchBusy = Observable(false);
  final ObservableList<ReverseImageSessionStep> sessionSteps =
      ObservableList<ReverseImageSessionStep>();
  final ObservableList<ReverseImageDisplayCandidate> sessionCandidates =
      ObservableList<ReverseImageDisplayCandidate>();
  final ObservableList<String> serviceMessages = ObservableList<String>();
  final StreamController<SauceSearchEvent> _streamController =
      StreamController<SauceSearchEvent>.broadcast(sync: true);

  Stream<SauceSearchEvent> get observableStream => _streamController.stream;

  @observable
  bool notStart = true;

  bool _disposed = false;
  bool _requestInProgress = false;
  bool _inlineResults = false;
  bool _externalUploadConfirmed = false;
  DateTime? _sessionStartedAt;
  DateTime? _sessionFinishedAt;
  Uint8List? _selectedOriginBytes;
  String? _selectedSha256;
  Uint8List? _preparedSearchBytes;
  String? _preparedSearchExtension;
  final List<ReverseImageProviderHit> _sessionHits = [];
  PixivBookmarkVisualSearchController? _bookmarkSearchController;
  BookmarkVisualSearchStatus? _lastBookmarkSearchStatus;
  String? _lastBookmarkSearchDetail;
  CancelToken? _externalCancelToken;
  CancelToken? _iqdbCancelToken;

  DateTime? get sessionStartedAt => _sessionStartedAt;

  DateTime? get sessionFinishedAt => _sessionFinishedAt;

  Duration get sessionElapsed {
    final started = _sessionStartedAt;
    if (started == null) return Duration.zero;
    return (_sessionFinishedAt ?? DateTime.now()).difference(started);
  }

  bool get _hasUsablePixivAccount {
    final userId = int.tryParse(accountStore.now?.userId ?? '');
    return userId != null && userId > 0;
  }

  bool get canSearchBookmarks {
    return !searchBusy.value &&
        _selectedOriginBytes != null &&
        _selectedSha256 != null &&
        _hasUsablePixivAccount;
  }

  bool get canRetryRegion => !searchBusy.value && _selectedOriginBytes != null;

  bool get canOpenAscii2d =>
      Platform.isAndroid &&
      !searchBusy.value &&
      (_preparedSearchBytes != null || _selectedOriginBytes != null);

  bool get canCancelSearch =>
      searchBusy.value &&
      (_bookmarkSearchController != null ||
          _externalCancelToken?.isCancelled == false ||
          _iqdbCancelToken?.isCancelled == false);

  ReverseImageSessionStepState get _bookmarkTerminalStepState =>
      switch (_lastBookmarkSearchStatus) {
        BookmarkVisualSearchStatus.cancelled =>
          ReverseImageSessionStepState.cancelled,
        BookmarkVisualSearchStatus.failed ||
        BookmarkVisualSearchStatus.accountChanged ||
        BookmarkVisualSearchStatus.unauthenticated =>
          ReverseImageSessionStepState.failed,
        _ => ReverseImageSessionStepState.noMatch,
      };

  String get _bookmarkTerminalDetail => switch (_lastBookmarkSearchStatus) {
    BookmarkVisualSearchStatus.cancelled => 'Bookmark scan cancelled',
    BookmarkVisualSearchStatus.limitReached => 'Bookmark scan limit reached',
    BookmarkVisualSearchStatus.incomplete => 'Bookmark scan was incomplete',
    BookmarkVisualSearchStatus.failed =>
      _lastBookmarkSearchDetail ?? 'Bookmark scan failed',
    BookmarkVisualSearchStatus.accountChanged =>
      'Pixiv account changed during the scan',
    BookmarkVisualSearchStatus.unauthenticated => 'No signed-in Pixiv account',
    _ => 'No bookmark candidate was confirmed',
  };

  void _resetSession({required bool inlineResults}) {
    _inlineResults = inlineResults;
    _externalUploadConfirmed = false;
    _sessionStartedAt = DateTime.now();
    _sessionFinishedAt = null;
    _selectedOriginBytes = null;
    _selectedSha256 = null;
    _preparedSearchBytes = null;
    _preparedSearchExtension = null;
    _sessionHits.clear();
    _lastBookmarkSearchStatus = null;
    _lastBookmarkSearchDetail = null;
    selectedFileName.value = null;
    selectedImageBytes.value = null;
    sessionCandidates.clear();
    serviceMessages.clear();
    sessionSteps
      ..clear()
      ..addAll(
        ReverseImageSessionStepId.values.map(
          (id) => ReverseImageSessionStep(
            id: id,
            state: ReverseImageSessionStepState.pending,
          ),
        ),
      );
  }

  void _updateSessionStep(
    ReverseImageSessionStepId id,
    ReverseImageSessionStepState state, {
    String? detail,
  }) {
    if (_disposed) return;
    final index = sessionSteps.indexWhere((step) => step.id == id);
    if (index < 0) return;
    final previous = sessionSteps[index];
    final now = DateTime.now();
    final restarted =
        state == ReverseImageSessionStepState.running &&
        previous.state != ReverseImageSessionStepState.running;
    sessionSteps[index] = previous.copyWith(
      state: state,
      detail: detail,
      startedAt: restarted ? now : previous.startedAt,
      endedAt: switch (state) {
        ReverseImageSessionStepState.running ||
        ReverseImageSessionStepState.pending => null,
        _ => now,
      },
      clearEndedAt: state == ReverseImageSessionStepState.running,
    );
  }

  void _replaceServiceMessages(Iterable<String> messages) {
    serviceMessages
      ..clear()
      ..addAll(messages.toSet());
  }

  void _recordExternalBatch(_ExternalSearchBatch batch) {
    _sessionHits.addAll(batch.hits);
    final candidates = buildReverseImageDisplayCandidates(_sessionHits);
    sessionCandidates
      ..clear()
      ..addAll(candidates);
    _replaceServiceMessages(<String>[
      ...serviceMessages,
      ...batch.serviceMessages,
    ]);
  }

  void _recordResolvedCandidate(
    int illustId, {
    required String providerId,
    double similarity = 100,
  }) {
    final hit = ReverseImageProviderHit(
      providerId: providerId,
      probe: ReverseImageProbeKind.full,
      illustId: illustId,
      similarity: similarity,
      sourceUrl: 'https://www.pixiv.net/artworks/$illustId',
      title: 'Pixiv #$illustId',
    );
    _sessionHits.add(hit);
    sessionCandidates
      ..clear()
      ..addAll(buildReverseImageDisplayCandidates(_sessionHits));
    _updateSessionStep(
      ReverseImageSessionStepId.results,
      ReverseImageSessionStepState.succeeded,
      detail: 'Pixiv #$illustId',
    );
  }

  void _finishSessionClock() {
    _sessionFinishedAt ??= DateTime.now();
  }

  void dispose() {
    _disposed = true;
    _externalCancelToken?.cancel('Image-search page disposed');
    _externalCancelToken = null;
    _iqdbCancelToken?.cancel('Image-search page disposed');
    _iqdbCancelToken = null;
    _bookmarkSearchController?.dispose();
    _bookmarkSearchController = null;
    _sauceDioClient.close();
    _iqdbProvider.close();
    unawaited(_streamController.close());
  }

  Future<SauceSearchEvent?> findImage({
    BuildContext? context,
    String? path,
    bool retry = false,
    bool inlineResults = false,
    bool skipBookmarkPrompt = false,
  }) async {
    if (_disposed || _requestInProgress) return null;
    _requestInProgress = true;
    searchBusy.value = true;

    try {
      final previousPhase = phase.value;
      String? pickedName;
      PlatformFile? pickedFile;
      if (path == null) {
        // Keep the completed session visible while Android's picker is open.
        // Cancelling "choose another image" must not erase candidates that the
        // user may still want to inspect.
        phase.value = SauceSearchPhase.picking;
        pickedFile = await _pickImage();
        if (_disposed) return null;
        if (pickedFile == null) {
          phase.value = previousPhase;
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

      _resetSession(inlineResults: inlineResults);
      results.clear();
      lastError.value = null;
      phase.value = SauceSearchPhase.inspecting;
      _updateSessionStep(
        ReverseImageSessionStepId.pick,
        ReverseImageSessionStepState.running,
        detail: pickedFile == null ? 'Shared image received' : 'Image selected',
      );
      final selectedPath = path;
      selectedFileName.value = pickedName;
      _updateSessionStep(
        ReverseImageSessionStepId.pick,
        ReverseImageSessionStepState.succeeded,
        detail: pickedName,
      );
      _updateSessionStep(
        ReverseImageSessionStepId.localIdentity,
        ReverseImageSessionStepState.running,
        detail: 'Checking filename, metadata and local fingerprints',
      );
      notStart = false;

      var localId = extractPixivIllustId(hints: [pickedName, selectedPath]);

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
      _selectedOriginBytes = originImageBytes;

      if (localId != null) {
        await _ensurePreparedSearchImage(originImageBytes);
        if (_disposed) return null;
        LPrinter.d('Reverse image search resolved Pixiv ID locally: $localId');
        BotToast.showText(text: 'Pixiv ID: $localId');
        _updateSessionStep(
          ReverseImageSessionStepId.localIdentity,
          ReverseImageSessionStepState.succeeded,
          detail: 'Pixiv ID found in the selected file name',
        );
        return _finish([localId], matchedLocally: true, providerId: 'filename');
      }

      BotToast.showText(text: I18n.ofContext().parsing);
      localId ??= await compute(
        extractPixivIllustIdFromBytes,
        originImageBytes,
      );
      if (_disposed) return null;
      if (localId != null) {
        await _ensurePreparedSearchImage(originImageBytes);
        if (_disposed) return null;
        LPrinter.d('Reverse image search resolved Pixiv ID locally: $localId');
        BotToast.showText(text: 'Pixiv ID: $localId');
        _updateSessionStep(
          ReverseImageSessionStepId.localIdentity,
          ReverseImageSessionStepState.succeeded,
          detail: 'Pixiv ID found in image metadata',
        );
        return _finish([localId], matchedLocally: true, providerId: 'metadata');
      }

      final fingerprints = await compute(
        computeDownloadImageFingerprints,
        originImageBytes,
      );
      _selectedSha256 = fingerprints['sha256'];
      if (_disposed) return null;
      final indexedIdentity = await downloadIdentityIndex.findDigest(
        fingerprints['sha256']!,
      );
      if (_disposed) return null;
      if (indexedIdentity != null) {
        await _ensurePreparedSearchImage(originImageBytes);
        if (_disposed) return null;
        localId = indexedIdentity.illustId;
        LPrinter.d(
          'Reverse image search resolved Pixiv ID by SHA-256: $localId',
        );
        BotToast.showText(text: 'Pixiv ID: $localId');
        _updateSessionStep(
          ReverseImageSessionStepId.localIdentity,
          ReverseImageSessionStepState.succeeded,
          detail: 'Exact local download fingerprint matched',
        );
        return _finish(
          [localId],
          matchedLocally: true,
          providerId: 'local-sha256',
        );
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
            await _ensurePreparedSearchImage(originImageBytes);
            if (_disposed) return null;
            localId = nearDuplicate.identity.illustId;
            LPrinter.d(
              'Reverse image search accepted local near duplicate: '
              '$localId (distance ${nearDuplicate.distance})',
            );
            BotToast.showText(text: 'Pixiv ID: $localId');
            _updateSessionStep(
              ReverseImageSessionStepId.localIdentity,
              ReverseImageSessionStepState.succeeded,
              detail: 'Confirmed local near-duplicate match',
            );
            return _finish(
              [localId],
              matchedLocally: true,
              providerId: 'local-dhash',
              similarity: nearDuplicate.similarity * 100,
            );
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
            await _ensurePreparedSearchImage(originImageBytes);
            if (_disposed) return null;
            localId = completedTask.illustId;
            LPrinter.d(
              'Reverse image search accepted historical download: $localId',
            );
            BotToast.showText(text: 'Pixiv ID: $localId');
            _updateSessionStep(
              ReverseImageSessionStepId.localIdentity,
              ReverseImageSessionStepState.succeeded,
              detail: 'Confirmed historical download record',
            );
            return _finish(
              [localId],
              matchedLocally: true,
              providerId: 'download-history',
            );
          }
        }
      }

      _updateSessionStep(
        ReverseImageSessionStepId.localIdentity,
        ReverseImageSessionStepState.noMatch,
        detail: 'No reliable local identity found',
      );
      phase.value = SauceSearchPhase.uploading;
      _updateSessionStep(
        ReverseImageSessionStepId.prepare,
        ReverseImageSessionStepState.running,
        detail: 'Preparing a bounded, metadata-free local preview',
      );
      final prepared = await _ensurePreparedSearchImage(originImageBytes);
      if (_disposed) return null;
      if (prepared == null) {
        _fail('Image is too large or unsupported');
        return null;
      }
      final preparedBytes = prepared['bytes'] as Uint8List;
      final preparedExtension = prepared['extension'] as String;
      _updateSessionStep(
        ReverseImageSessionStepId.prepare,
        ReverseImageSessionStepState.succeeded,
        detail: '${preparedBytes.length ~/ 1024} KB safe preview',
      );
      LPrinter.d(
        'Reverse image upload size: ${originImageBytes.length} -> '
        '${preparedBytes.length}',
      );

      if (context == null || !context.mounted) {
        _fail('External image search requires confirmation');
        return null;
      }

      if (skipBookmarkPrompt) {
        _updateSessionStep(
          ReverseImageSessionStepId.bookmarks,
          ReverseImageSessionStepState.skipped,
          detail: !_hasUsablePixivAccount
              ? 'Sign in to scan your Pixiv bookmarks'
              : 'Skipped for fast search; available as a separate action',
        );
      } else if (_hasUsablePixivAccount) {
        final bookmarkChoice = await showBookmarkSearchChoiceDialog(context);
        if (_disposed || !context.mounted) return null;
        if (bookmarkChoice == BookmarkSearchChoice.cancel) {
          notStart = true;
          phase.value = SauceSearchPhase.idle;
          return null;
        }
        if (bookmarkChoice == BookmarkSearchChoice.scanBookmarks) {
          _updateSessionStep(
            ReverseImageSessionStepId.bookmarks,
            ReverseImageSessionStepState.running,
            detail: 'Scanning public and private bookmarks',
          );
          final bookmarkEvent = await _searchOwnBookmarks(
            context: context,
            queryBytes: originImageBytes,
            queryFileName: pickedName,
            querySha256: fingerprints['sha256']!,
          );
          if (_disposed || !context.mounted) return null;
          if (bookmarkEvent != null) return bookmarkEvent;
          _updateSessionStep(
            ReverseImageSessionStepId.bookmarks,
            _bookmarkTerminalStepState,
            detail: _bookmarkTerminalDetail,
          );
        } else {
          _updateSessionStep(
            ReverseImageSessionStepId.bookmarks,
            ReverseImageSessionStepState.skipped,
            detail: 'User chose external image search',
          );
        }
      } else {
        _updateSessionStep(
          ReverseImageSessionStepId.bookmarks,
          ReverseImageSessionStepState.skipped,
          detail: 'No signed-in Pixiv account',
        );
      }

      final uploadConfirmed = await _confirmExternalUpload(context);
      if (_disposed || !context.mounted) return null;
      if (!uploadConfirmed) {
        notStart = false;
        phase.value = SauceSearchPhase.idle;
        _updateSessionStep(
          ReverseImageSessionStepId.sauceNao,
          ReverseImageSessionStepState.cancelled,
          detail: 'External upload was not approved',
        );
        _updateSessionStep(
          ReverseImageSessionStepId.iqdb,
          ReverseImageSessionStepState.cancelled,
          detail: 'External upload was not approved',
        );
        _finishSessionClock();
        return null;
      }
      _externalUploadConfirmed = true;

      phase.value = SauceSearchPhase.parsing;
      BotToast.showText(text: 'SauceNAO + IQDB · ${I18n.ofContext().parsing}');
      var batch = await _searchExternalProviders(
        preparedBytes,
        preparedExtension,
        ReverseImageProbeKind.full,
      );
      if (_disposed || !context.mounted) return null;
      if (batch.cancelled) {
        final hasCandidates = sessionCandidates.isNotEmpty;
        _updateSessionStep(
          ReverseImageSessionStepId.results,
          hasCandidates
              ? ReverseImageSessionStepState.succeeded
              : ReverseImageSessionStepState.cancelled,
          detail: hasCandidates
              ? '${sessionCandidates.length} candidate(s) retained before cancellation'
              : 'Search cancelled before a reliable candidate was found',
        );
        notStart = false;
        phase.value = hasCandidates
            ? SauceSearchPhase.success
            : SauceSearchPhase.cancelled;
        _finishSessionClock();
        return SauceSearchEvent(
          illustIds: sessionCandidates
              .map((candidate) => candidate.illustId)
              .whereType<int>()
              .toList(growable: false),
          matchedLocally: false,
        );
      }

      if (inlineResults) {
        final hasCandidates = sessionCandidates.isNotEmpty;
        final providersUnavailable = batch.successfulProviders == 0;
        _updateSessionStep(
          ReverseImageSessionStepId.results,
          hasCandidates
              ? ReverseImageSessionStepState.succeeded
              : (providersUnavailable
                    ? ReverseImageSessionStepState.failed
                    : ReverseImageSessionStepState.noMatch),
          detail: hasCandidates
              ? '${sessionCandidates.length} candidate(s) retained'
              : (providersUnavailable
                    ? 'External image-search services were unavailable'
                    : 'No reliable full-image candidate'),
        );
        notStart = false;
        phase.value = hasCandidates
            ? SauceSearchPhase.success
            : (providersUnavailable
                  ? SauceSearchPhase.error
                  : SauceSearchPhase.noResult);
        if (providersUnavailable) {
          lastError.value = batch.serviceMessages.isEmpty
              ? 'External image-search services were unavailable'
              : batch.serviceMessages.join('\n');
        }
        _finishSessionClock();
        return SauceSearchEvent(
          illustIds: sessionCandidates
              .map((candidate) => candidate.illustId)
              .whereType<int>()
              .toList(growable: false),
          matchedLocally: false,
        );
      }

      var decision = await _resolveExternalCandidates(context, batch.hits);
      if (_disposed || !context.mounted) return null;
      var accepted = decision?.hit;
      if (accepted != null) {
        final illustId = accepted.illustId;
        if (illustId != null) {
          return _finish(
            [illustId],
            matchedLocally: false,
            providerId: accepted.providerId,
            similarity: accepted.similarity,
          );
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
                return _finish(
                  [illustId],
                  matchedLocally: false,
                  providerId: accepted.providerId,
                  similarity: accepted.similarity,
                );
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
        if (await _offerAscii2dFallback(context, preparedBytes)) return null;
        _fail(batch.serviceMessages.join('\n'));
        return null;
      }
      if (await _offerAscii2dFallback(context, preparedBytes)) return null;
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
      if (!_disposed) searchBusy.value = false;
    }
  }

  Future<SauceSearchEvent?> _searchOwnBookmarks({
    required BuildContext context,
    required Uint8List queryBytes,
    required String querySha256,
    String? queryFileName,
  }) async {
    PixivBookmarkVisualSearchController? controller;
    _lastBookmarkSearchStatus = null;
    _lastBookmarkSearchDetail = null;
    try {
      phase.value = SauceSearchPhase.inspecting;
      const limits = BookmarkVisualSearchLimits(
        maximumPagesPerVisibility: 30,
        maximumWorks: 1800,
        maximumImages: 2400,
        downloadConcurrency: 2,
        maximumDistance: 4,
        minimumDistanceGap: 3,
      );
      controller = await PixivBookmarkVisualSearchController.createDefault(
        limits: limits,
      );
      if (_disposed || !context.mounted) {
        controller.dispose();
        return null;
      }
      _bookmarkSearchController?.dispose();
      _bookmarkSearchController = controller;

      late BookmarkVisualSearchResult result;
      BookmarkVisualCandidate? candidate;
      var fullScanRequested = false;
      while (true) {
        final activeController = controller;
        if (activeController == null) return null;
        final searchResult = await showBookmarkVisualSearchProgressDialog(
          context: context,
          controller: activeController,
          queryBytes: queryBytes,
          queryFileName: queryFileName,
        );
        if (_disposed || !context.mounted) return null;
        if (searchResult == null) {
          _lastBookmarkSearchStatus = BookmarkVisualSearchStatus.cancelled;
          return null;
        }
        result = searchResult;
        _lastBookmarkSearchStatus = result.status;
        if (result.status == BookmarkVisualSearchStatus.failed) {
          _lastBookmarkSearchDetail = describeBookmarkVisualSearchFailure(
            result.error,
          );
        }
        phase.value = SauceSearchPhase.inspecting;

        final canReviewCandidates = switch (result.status) {
          BookmarkVisualSearchStatus.matched ||
          BookmarkVisualSearchStatus.ambiguous ||
          BookmarkVisualSearchStatus.incomplete ||
          BookmarkVisualSearchStatus.limitReached => true,
          _ => false,
        };
        if (!canReviewCandidates ||
            (result.match == null && result.candidates.isEmpty)) {
          break;
        }

        final decision = await showBookmarkVisualCandidatesDialog(
          context: context,
          result: result,
          queryBytes: queryBytes,
          controller: activeController,
        );
        if (_disposed || !context.mounted) return null;
        if (decision.type == BookmarkVisualCandidateDecisionType.selected) {
          candidate = decision.candidate;
          break;
        }
        if (decision.type !=
                BookmarkVisualCandidateDecisionType.continueScanning ||
            fullScanRequested) {
          break;
        }

        // A zero-distance dHash is still a visual hint. If the user rejects an
        // early candidate, rerun without perceptual early exit so a newer
        // collision cannot hide the real work on later bookmark pages.
        fullScanRequested = true;
        if (identical(_bookmarkSearchController, activeController)) {
          _bookmarkSearchController = null;
        }
        activeController.dispose();
        controller = await PixivBookmarkVisualSearchController.createDefault(
          limits: limits,
          allowEarlyExactPerceptualMatch: false,
        );
        if (_disposed || !context.mounted) {
          controller.dispose();
          return null;
        }
        _bookmarkSearchController = controller;
      }
      if (candidate != null) {
        final confirmationResult =
            result.match?.illustId == candidate.illustId &&
                result.match?.pageIndex == candidate.pageIndex
            ? result
            : BookmarkVisualSearchResult(
                status: BookmarkVisualSearchStatus.matched,
                match: candidate,
                candidates: result.candidates,
                progress: result.progress,
                scanComplete: result.scanComplete,
                requiresConfirmation: true,
                querySha256: querySha256,
              );
        try {
          final cached = await controller!.confirmMatch(
            result: confirmationResult,
            queryBytes: queryBytes,
            queryFileName: queryFileName,
          );
          if (!cached) {
            _lastBookmarkSearchStatus = BookmarkVisualSearchStatus.failed;
            _lastBookmarkSearchDetail =
                'Confirmed candidate could not be cached';
            final chinese =
                Localizations.localeOf(context).languageCode == 'zh';
            BotToast.showText(
              text: chinese
                  ? '候选确认失败，未写入本地索引'
                  : 'The candidate could not be confirmed and was not cached',
            );
            return null;
          }
        } catch (error, stackTrace) {
          // The user has visually confirmed the Pixiv candidate. A cache write
          // failure must not hide the confirmed artwork from this search.
          LPrinter.d('Unable to cache confirmed bookmark match: $error');
          LPrinter.d(stackTrace);
        }
        _updateSessionStep(
          ReverseImageSessionStepId.bookmarks,
          ReverseImageSessionStepState.succeeded,
          detail: 'Confirmed in your Pixiv bookmarks',
        );
        _lastBookmarkSearchStatus = BookmarkVisualSearchStatus.matched;
        return _finish(
          [candidate.illustId],
          matchedLocally: true,
          providerId: 'bookmarks',
          similarity: (candidate.similarity ?? 1) * 100,
        );
      }

      if (result.status != BookmarkVisualSearchStatus.cancelled) {
        final chinese = Localizations.localeOf(context).languageCode == 'zh';
        final message = switch (result.status) {
          BookmarkVisualSearchStatus.notFound =>
            chinese
                ? '在已扫描的收藏中没有找到，可继续使用外部识图'
                : 'No match in the scanned bookmarks; external search is still available',
          BookmarkVisualSearchStatus.limitReached =>
            chinese
                ? '已达到收藏扫描上限，未找到可确认候选'
                : 'The bookmark scan limit was reached without a confirmed candidate',
          BookmarkVisualSearchStatus.incomplete =>
            chinese
                ? '部分收藏预览图无法读取，未找到可确认候选'
                : 'Some bookmark previews could not be read and no candidate was confirmed',
          BookmarkVisualSearchStatus.accountChanged =>
            chinese
                ? '扫描期间 Pixiv 账号已变更，已停止'
                : 'The selected Pixiv account changed, so the scan was stopped',
          BookmarkVisualSearchStatus.unauthenticated =>
            chinese
                ? '当前没有可用的 Pixiv 登录账号'
                : 'No signed-in Pixiv account is available',
          BookmarkVisualSearchStatus.ambiguous =>
            chinese
                ? '收藏中有多个过于接近的候选，未自动记录'
                : 'Several bookmark candidates were too close; nothing was cached',
          BookmarkVisualSearchStatus.failed =>
            chinese
                ? '收藏扫描失败，可继续使用外部识图'
                : 'Bookmark scanning failed; external search is still available',
          BookmarkVisualSearchStatus.matched ||
          BookmarkVisualSearchStatus.cancelled => '',
        };
        if (message.isNotEmpty) BotToast.showText(text: message);
      }
      return null;
    } catch (error, stackTrace) {
      _lastBookmarkSearchStatus = BookmarkVisualSearchStatus.failed;
      _lastBookmarkSearchDetail = describeBookmarkVisualSearchFailure(error);
      LPrinter.d('Bookmark visual search failed: $error\n$stackTrace');
      if (!_disposed && context.mounted) {
        final chinese = Localizations.localeOf(context).languageCode == 'zh';
        BotToast.showText(
          text: chinese
              ? '无法扫描收藏，可继续使用外部识图'
              : 'Bookmarks could not be scanned; external search is still available',
        );
      }
      return null;
    } finally {
      if (identical(_bookmarkSearchController, controller)) {
        _bookmarkSearchController = null;
      }
      controller?.dispose();
    }
  }

  Future<SauceSearchEvent?> searchSelectedImageInBookmarks(
    BuildContext context,
  ) async {
    final bytes = _selectedOriginBytes;
    final sha256 = _selectedSha256;
    if (_disposed ||
        _requestInProgress ||
        bytes == null ||
        sha256 == null ||
        !context.mounted) {
      return null;
    }
    _requestInProgress = true;
    searchBusy.value = true;
    lastError.value = null;
    _sessionFinishedAt = null;
    phase.value = SauceSearchPhase.inspecting;
    _updateSessionStep(
      ReverseImageSessionStepId.bookmarks,
      ReverseImageSessionStepState.running,
      detail: 'Scanning public and private bookmarks',
    );
    try {
      final event = await _searchOwnBookmarks(
        context: context,
        queryBytes: bytes,
        queryFileName: selectedFileName.value,
        querySha256: sha256,
      );
      if (_disposed || !context.mounted) return null;
      if (event == null) {
        final bookmarkStatus = _lastBookmarkSearchStatus;
        final stepState = switch (bookmarkStatus) {
          BookmarkVisualSearchStatus.cancelled =>
            ReverseImageSessionStepState.cancelled,
          BookmarkVisualSearchStatus.failed ||
          BookmarkVisualSearchStatus.accountChanged ||
          BookmarkVisualSearchStatus.unauthenticated =>
            ReverseImageSessionStepState.failed,
          _ => ReverseImageSessionStepState.noMatch,
        };
        _updateSessionStep(
          ReverseImageSessionStepId.bookmarks,
          stepState,
          detail: _bookmarkTerminalDetail,
        );
        phase.value = sessionCandidates.isEmpty
            ? SauceSearchPhase.noResult
            : SauceSearchPhase.success;
        _finishSessionClock();
      }
      return event;
    } finally {
      _requestInProgress = false;
      if (!_disposed) searchBusy.value = false;
    }
  }

  void cancelCurrentSearch() {
    if (_disposed) return;

    final bookmarkController = _bookmarkSearchController;
    if (bookmarkController != null) {
      bookmarkController.cancel();
      _lastBookmarkSearchStatus = BookmarkVisualSearchStatus.cancelled;
      _lastBookmarkSearchDetail = 'Bookmark scan cancelled';
    }

    final externalToken = _externalCancelToken;
    if (externalToken != null && !externalToken.isCancelled) {
      externalToken.cancel('Cancelled by user');
    }
    final iqdbToken = _iqdbCancelToken;
    if (iqdbToken != null && !iqdbToken.isCancelled) {
      iqdbToken.cancel('Cancelled by user');
    }
    for (final stepId in const <ReverseImageSessionStepId>[
      ReverseImageSessionStepId.bookmarks,
      ReverseImageSessionStepId.sauceNao,
      ReverseImageSessionStepId.iqdb,
      ReverseImageSessionStepId.crop,
    ]) {
      final index = sessionSteps.indexWhere((item) => item.id == stepId);
      if (index >= 0 &&
          sessionSteps[index].state == ReverseImageSessionStepState.running) {
        _updateSessionStep(
          stepId,
          ReverseImageSessionStepState.cancelled,
          detail: 'Cancelled by user',
        );
      }
    }
  }

  Future<void> retrySelectedRegion(
    BuildContext context,
    ReverseImageProbeKind probe,
  ) async {
    final originBytes = _selectedOriginBytes;
    if (_disposed ||
        _requestInProgress ||
        originBytes == null ||
        probe == ReverseImageProbeKind.full ||
        !context.mounted) {
      return;
    }
    _requestInProgress = true;
    searchBusy.value = true;
    lastError.value = null;
    try {
      if (!_externalUploadConfirmed) {
        final confirmed = await _confirmExternalUpload(context);
        if (!confirmed || _disposed || !context.mounted) return;
        _externalUploadConfirmed = true;
      }

      _sessionFinishedAt = null;
      phase.value = SauceSearchPhase.uploading;
      _updateSessionStep(
        ReverseImageSessionStepId.crop,
        ReverseImageSessionStepState.running,
        detail: 'Preparing ${probe.name} region',
      );
      final cropped = await compute(_prepareExternalSearchCrop, {
        'bytes': originBytes,
        'probe': probe.name,
      });
      if (_disposed || !context.mounted) return;
      if (cropped == null) {
        _updateSessionStep(
          ReverseImageSessionStepId.crop,
          ReverseImageSessionStepState.failed,
          detail: 'The selected region could not be prepared',
        );
        _fail('Image region is too large or unsupported');
        return;
      }
      final cropBytes = cropped['bytes'] as Uint8List;
      final cropExtension = cropped['extension'] as String;
      phase.value = SauceSearchPhase.parsing;
      final batch = await _searchExternalProviders(
        cropBytes,
        cropExtension,
        probe,
      );
      if (_disposed || !context.mounted) return;
      if (batch.cancelled) {
        final hasCandidates = sessionCandidates.isNotEmpty;
        _updateSessionStep(
          ReverseImageSessionStepId.crop,
          ReverseImageSessionStepState.cancelled,
          detail: 'Region search cancelled by user',
        );
        _updateSessionStep(
          ReverseImageSessionStepId.results,
          hasCandidates
              ? ReverseImageSessionStepState.succeeded
              : ReverseImageSessionStepState.cancelled,
          detail: hasCandidates
              ? '${sessionCandidates.length} earlier candidate(s) retained'
              : 'Search cancelled before a reliable candidate was found',
        );
        notStart = false;
        phase.value = hasCandidates
            ? SauceSearchPhase.success
            : SauceSearchPhase.cancelled;
        _finishSessionClock();
        return;
      }
      final retainedFromProbe = sessionCandidates
          .where(
            (candidate) =>
                candidate.evidence.any((evidence) => evidence.probe == probe),
          )
          .length;
      final cropState = batch.successfulProviders == 0
          ? ReverseImageSessionStepState.failed
          : (retainedFromProbe == 0
                ? ReverseImageSessionStepState.noMatch
                : ReverseImageSessionStepState.succeeded);
      _updateSessionStep(
        ReverseImageSessionStepId.crop,
        cropState,
        detail: batch.successfulProviders == 0
            ? 'Both external providers failed for ${probe.name}'
            : (retainedFromProbe == 0
                  ? 'No reliable candidate in ${probe.name} region'
                  : '$retainedFromProbe retained candidate(s) from '
                        '${probe.name} region'),
      );
      final hasCandidates = sessionCandidates.isNotEmpty;
      final providersUnavailable = batch.successfulProviders == 0;
      _updateSessionStep(
        ReverseImageSessionStepId.results,
        hasCandidates
            ? ReverseImageSessionStepState.succeeded
            : (providersUnavailable
                  ? ReverseImageSessionStepState.failed
                  : ReverseImageSessionStepState.noMatch),
        detail: hasCandidates
            ? '${sessionCandidates.length} candidate(s) retained'
            : (providersUnavailable
                  ? 'External image-search services were unavailable'
                  : 'No reliable candidate after region search'),
      );
      notStart = false;
      phase.value = hasCandidates
          ? SauceSearchPhase.success
          : (providersUnavailable
                ? SauceSearchPhase.error
                : SauceSearchPhase.noResult);
      if (providersUnavailable) {
        lastError.value = batch.serviceMessages.isEmpty
            ? 'External image-search services were unavailable'
            : batch.serviceMessages.join('\n');
      }
      _finishSessionClock();
    } catch (error, stackTrace) {
      LPrinter.d('Region reverse image search failed: $error\n$stackTrace');
      _updateSessionStep(
        ReverseImageSessionStepId.crop,
        ReverseImageSessionStepState.failed,
        detail: 'The selected region search failed',
      );
      _fail('Region image search failed');
    } finally {
      _requestInProgress = false;
      if (!_disposed) searchBusy.value = false;
    }
  }

  Future<void> openAscii2dForCurrentImage(BuildContext context) async {
    if (_disposed || _requestInProgress || !context.mounted) return;
    final originBytes = _selectedOriginBytes;
    if (originBytes == null) return;
    _requestInProgress = true;
    searchBusy.value = true;
    try {
      final prepared = await _ensurePreparedSearchImage(originBytes);
      if (_disposed || !context.mounted || prepared == null) return;
      final preparedBytes = prepared['bytes'] as Uint8List;
      await _offerAscii2dFallback(context, preparedBytes);
    } finally {
      _requestInProgress = false;
      if (!_disposed) searchBusy.value = false;
    }
  }

  Future<bool> _offerAscii2dFallback(
    BuildContext context,
    Uint8List sanitizedImageBytes,
  ) async {
    if (!Platform.isAndroid || _disposed || !context.mounted) return false;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final hasCandidates = sessionCandidates.isNotEmpty;
    final open =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              chinese
                  ? (hasCandidates ? '继续查找更多来源？' : '外部索引未找到原作')
                  : (hasCandidates
                        ? 'Search for more sources?'
                        : 'No source in the external indexes'),
            ),
            content: Text(
              chinese
                  ? '${hasCandidates ? '当前候选会保留。' : 'SauceNAO 和 IQDB 未找到可靠候选。'}'
                        '可以在 Ascii2D 官方网页继续：完整图用「色合搜索」，裁剪图或局部图用「特征搜索」。只有你在下一页再次点击「使用这张图」后，去除元数据的副本才会交给 Ascii2D。'
                  : '${hasCandidates ? 'The current candidates will remain. ' : 'SauceNAO and IQDB found no reliable candidate. '}'
                        'Continue on the official Ascii2D page: use color '
                        'search for a complete image and feature search for a '
                        'crop or partial image. The metadata-free copy is '
                        'handed to Ascii2D only after you tap Use this image '
                        'again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(chinese ? '暂不' : 'Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(chinese ? '打开 Ascii2D' : 'Open Ascii2D'),
              ),
            ],
          ),
        ) ??
        false;
    if (!open || _disposed || !context.mounted) return false;

    await Navigator.of(context).push(
      Ascii2dBrowserSearchPage.route(sanitizedImageBytes: sanitizedImageBytes),
    );
    if (!_disposed) {
      notStart = false;
      phase.value = sessionCandidates.isEmpty
          ? SauceSearchPhase.noResult
          : SauceSearchPhase.success;
    }
    return true;
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

  Future<Map<String, Object>?> _ensurePreparedSearchImage(
    Uint8List originBytes,
  ) async {
    final cachedBytes = _preparedSearchBytes;
    final cachedExtension = _preparedSearchExtension;
    if (cachedBytes != null && cachedExtension != null) {
      return <String, Object>{
        'bytes': cachedBytes,
        'extension': cachedExtension,
      };
    }
    final prepared = await compute(_prepareExternalSearchImage, originBytes);
    if (_disposed || prepared == null) return null;
    final bytes = prepared['bytes'] as Uint8List;
    final extension = prepared['extension'] as String;
    _preparedSearchBytes = bytes;
    _preparedSearchExtension = extension;
    // Never hand an unvalidated, potentially huge compressed image directly to
    // Image.memory. The same bounded, metadata-free copy used for provider
    // search is safe to keep as the on-page preview.
    selectedImageBytes.value = bytes;
    return <String, Object>{'bytes': bytes, 'extension': extension};
  }

  Future<SauceNaoPixivResults> _searchSauceNao(
    Uint8List bytes,
    String extension, {
    required bool pixivOnly,
    required CancelToken cancelToken,
  }) async {
    final form = <String, dynamic>{
      if (pixivOnly) 'dbs[]': '5' else 'db': '999',
      'file': MultipartFile.fromBytes(
        bytes,
        filename: 'pixez_reverse_search.$extension',
      ),
    };
    final response = await _sauceDioClient.run(
      (dio) => dio.post<dynamic>(
        '/search.php',
        data: FormData.fromMap(form),
        cancelToken: cancelToken,
      ),
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
    final cancelToken = CancelToken();
    final iqdbCancelToken = CancelToken();
    _externalCancelToken = cancelToken;
    _iqdbCancelToken = iqdbCancelToken;
    _updateSessionStep(
      ReverseImageSessionStepId.sauceNao,
      ReverseImageSessionStepState.running,
      detail: 'Searching the Pixiv index',
    );
    _updateSessionStep(
      ReverseImageSessionStepId.iqdb,
      ReverseImageSessionStepState.running,
      detail: 'Searching IQDB indexes',
    );

    // SauceNAO and IQDB are independent services. Running the IQDB request in
    // parallel with SauceNAO's db5 -> conditional db999 chain preserves the
    // same request count and confidence rules while removing one full network
    // timeout from the critical path.
    Future<_ExternalSearchBatch> recordWhenReady(
      Future<_ExternalSearchBatch> future,
    ) async {
      final batch = await future;
      if (!_disposed && !cancelToken.isCancelled) {
        _recordExternalBatch(batch);
      }
      return batch;
    }

    try {
      final branches = await Future.wait<_ExternalSearchBatch>([
        recordWhenReady(
          _searchSauceProvider(bytes, extension, probe, cancelToken),
        ),
        recordWhenReady(
          _searchIqdbProvider(
            bytes,
            extension,
            probe,
            iqdbCancelToken,
            cancelToken,
          ),
        ),
      ]);
      return branches[0]
          .merge(branches[1])
          .copyWith(cancelled: cancelToken.isCancelled);
    } finally {
      if (identical(_externalCancelToken, cancelToken)) {
        _externalCancelToken = null;
      }
      if (identical(_iqdbCancelToken, iqdbCancelToken)) {
        _iqdbCancelToken = null;
      }
    }
  }

  Future<_ExternalSearchBatch> _searchSauceProvider(
    Uint8List bytes,
    String extension,
    ReverseImageProbeKind probe,
    CancelToken cancelToken,
  ) async {
    final hits = <ReverseImageProviderHit>[];
    final messages = <String>[];
    var successfulProviders = 0;

    SauceNaoPixivResults? sauceResults;
    try {
      sauceResults = await _searchSauceNao(
        bytes,
        extension,
        pixivOnly: true,
        cancelToken: cancelToken,
      );
      successfulProviders++;
    } on SauceNaoResponseException catch (error) {
      messages.add(error.message);
      LPrinter.d('SauceNAO provider unavailable: ${error.message}');
    } on DioException catch (error) {
      if (!CancelToken.isCancel(error)) {
        final message = _dioMessage(error);
        messages.add(message);
        LPrinter.d('SauceNAO provider unavailable: $message');
      }
    } catch (error, stackTrace) {
      const message = 'SauceNAO returned an unsupported response';
      messages.add(message);
      LPrinter.d('$message: $error\n$stackTrace');
    }

    if (!cancelToken.isCancelled &&
        sauceResults != null &&
        !sauceResults.hasPixivCandidates) {
      _updateSessionStep(
        ReverseImageSessionStepId.sauceNao,
        ReverseImageSessionStepState.running,
        detail: 'Pixiv index had no exact match; searching all indexes',
      );
      LPrinter.d(
        'SauceNAO db5 returned no high-confidence Pixiv candidate; '
        'trying db999',
      );
      try {
        final allDatabaseResults = await _searchSauceNao(
          bytes,
          extension,
          pixivOnly: false,
          cancelToken: cancelToken,
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
        if (!CancelToken.isCancel(error)) {
          final message = _dioMessage(error);
          messages.add(message);
          LPrinter.d('SauceNAO all-database fallback unavailable: $message');
        }
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
            thumbnailUrl: candidate.thumbnailUrl,
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
            thumbnailUrl: candidate.thumbnailUrl,
          ),
        );
      }
    }

    final sauceCandidateCount = hits.length;
    _updateSessionStep(
      ReverseImageSessionStepId.sauceNao,
      cancelToken.isCancelled
          ? ReverseImageSessionStepState.cancelled
          : successfulProviders > 0
          ? (sauceCandidateCount > 0
                ? ReverseImageSessionStepState.succeeded
                : ReverseImageSessionStepState.noMatch)
          : ReverseImageSessionStepState.failed,
      detail: cancelToken.isCancelled
          ? 'Cancelled by user'
          : successfulProviders > 0
          ? '$sauceCandidateCount candidate(s)'
          : (messages.isEmpty ? 'SauceNAO unavailable' : messages.join(' · ')),
    );

    return _ExternalSearchBatch(
      hits: List.unmodifiable(hits),
      successfulProviders: successfulProviders,
      serviceMessages: List.unmodifiable(messages),
    );
  }

  Future<_ExternalSearchBatch> _searchIqdbProvider(
    Uint8List bytes,
    String extension,
    ReverseImageProbeKind probe,
    CancelToken requestCancelToken,
    CancelToken sessionCancelToken,
  ) async {
    final hits = <ReverseImageProviderHit>[];
    final messages = <String>[];
    var successfulProviders = 0;

    try {
      final iqdbResponse = await _iqdbProvider.searchWithCancel(
        ReverseImageQuery(bytes: bytes, extension: extension, probe: probe),
        cancelToken: requestCancelToken,
      );
      if (sessionCancelToken.isCancelled) {
        // Cancellation is a user action, not a provider failure.
      } else if (iqdbResponse.serviceMessage == null) {
        successfulProviders++;
      } else {
        messages.add(iqdbResponse.serviceMessage!);
        LPrinter.d('IQDB provider unavailable: ${iqdbResponse.serviceMessage}');
      }
      if (!sessionCancelToken.isCancelled) hits.addAll(iqdbResponse.hits);
    } catch (error, stackTrace) {
      const message = 'IQDB returned an unsupported response';
      messages.add(message);
      LPrinter.d('$message: $error\n$stackTrace');
    }

    _updateSessionStep(
      ReverseImageSessionStepId.iqdb,
      sessionCancelToken.isCancelled
          ? ReverseImageSessionStepState.cancelled
          : successfulProviders > 0
          ? (hits.isNotEmpty
                ? ReverseImageSessionStepState.succeeded
                : ReverseImageSessionStepState.noMatch)
          : ReverseImageSessionStepState.failed,
      detail: sessionCancelToken.isCancelled
          ? 'Cancelled by user'
          : successfulProviders > 0
          ? '${hits.length} candidate(s)'
          : (messages.isEmpty ? 'IQDB unavailable' : messages.join(' · ')),
    );

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

  SauceSearchEvent _finish(
    Iterable<int> ids, {
    required bool matchedLocally,
    String providerId = 'local',
    double similarity = 100,
  }) {
    final unique = <int>{...ids}.toList(growable: false);
    final event = SauceSearchEvent(
      illustIds: unique,
      matchedLocally: matchedLocally,
    );
    if (_disposed) return event;
    results
      ..clear()
      ..addAll(unique);
    for (final illustId in unique) {
      _recordResolvedCandidate(
        illustId,
        providerId: providerId,
        similarity: similarity,
      );
    }
    notStart = false;
    phase.value = SauceSearchPhase.success;
    _finishSessionClock();
    if (!_inlineResults) _streamController.add(event);
    return event;
  }

  void _fail(String message) {
    if (_disposed) return;
    notStart = false;
    lastError.value = message;
    phase.value = SauceSearchPhase.error;
    final runningIndex = sessionSteps.indexWhere(
      (step) => step.state == ReverseImageSessionStepState.running,
    );
    if (runningIndex >= 0) {
      _updateSessionStep(
        sessionSteps[runningIndex].id,
        ReverseImageSessionStepState.failed,
        detail: message,
      );
    }
    _finishSessionClock();
    BotToast.showText(text: message);
  }

  String _dioMessage(DioException error) {
    return describeExternalSearchFailure('SauceNAO', error);
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
  final bool cancelled;

  const _ExternalSearchBatch({
    required this.hits,
    required this.successfulProviders,
    required this.serviceMessages,
    this.cancelled = false,
  });

  _ExternalSearchBatch copyWith({bool? cancelled}) => _ExternalSearchBatch(
    hits: hits,
    successfulProviders: successfulProviders,
    serviceMessages: serviceMessages,
    cancelled: cancelled ?? this.cancelled,
  );

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
      cancelled: cancelled || other.cancelled,
    );
  }
}
