import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'image_perceptual_hash.dart';

enum BookmarkVisibility { public, private }

enum BookmarkVisualSearchStatus {
  matched,
  notFound,
  ambiguous,
  cancelled,
  unauthenticated,
  accountChanged,
  incomplete,
  limitReached,
  failed,
}

enum BookmarkVisualMatchKind { exactBytes, exactPerceptual, nearPerceptual }

class BookmarkVisualImageReference {
  final int pageIndex;
  final String url;

  const BookmarkVisualImageReference({
    required this.pageIndex,
    required this.url,
  });
}

class BookmarkVisualWork {
  final int illustId;
  final List<BookmarkVisualImageReference> images;

  const BookmarkVisualWork({required this.illustId, required this.images});
}

class BookmarkVisualPage {
  final List<BookmarkVisualWork> works;
  final int? nextOffset;

  const BookmarkVisualPage({required this.works, this.nextOffset});
}

/// A source that can only expose the account currently selected in PixEz.
///
/// Search callers never supply a target user ID. The service snapshots
/// [currentUserId] and passes that value back as [expectedUserId] on every page
/// request, allowing adapters to reject account switches before issuing a
/// private-bookmark request.
abstract interface class CurrentUserBookmarkVisualSource {
  int? get currentUserId;

  Future<BookmarkVisualPage> loadPage({
    required int expectedUserId,
    required BookmarkVisibility visibility,
    required int? offset,
    required BookmarkVisualCancellationToken cancellationToken,
  });
}

abstract interface class BookmarkVisualImageFetcher {
  Future<Uint8List> fetch(
    BookmarkVisualImageReference image,
    BookmarkVisualCancellationToken cancellationToken,
  );
}

class BookmarkVisualFingerprint {
  final String sha256;
  final String? differenceHash;

  const BookmarkVisualFingerprint({
    required this.sha256,
    required this.differenceHash,
  });
}

abstract interface class BookmarkVisualFingerprintComputer {
  Future<BookmarkVisualFingerprint> compute(Uint8List bytes);
}

class BookmarkVisualIndexRecord {
  final String sha256;
  final String? differenceHash;
  final int illustId;
  final int pageIndex;
  final String? fileName;

  const BookmarkVisualIndexRecord({
    required this.sha256,
    required this.differenceHash,
    required this.illustId,
    required this.pageIndex,
    this.fileName,
  });
}

abstract interface class BookmarkVisualIdentitySink {
  Future<void> remember(BookmarkVisualIndexRecord record);
}

class BookmarkVisualCancellationToken {
  bool _isCancelled = false;
  final Set<void Function()> _listeners = <void Function()>{};

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    for (final listener in _listeners.toList(growable: false)) {
      listener();
    }
    _listeners.clear();
  }

  void addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }
}

class BookmarkVisualSearchLimits {
  final int maximumPagesPerVisibility;
  final int maximumWorks;
  final int maximumImages;
  final int downloadConcurrency;
  final int maximumDistance;
  final int minimumDistanceGap;

  const BookmarkVisualSearchLimits({
    this.maximumPagesPerVisibility = 50,
    this.maximumWorks = 3000,
    this.maximumImages = 6000,
    this.downloadConcurrency = 2,
    this.maximumDistance = 4,
    this.minimumDistanceGap = 2,
  });

  void validate() {
    if (maximumPagesPerVisibility <= 0 ||
        maximumWorks <= 0 ||
        maximumImages <= 0 ||
        downloadConcurrency <= 0) {
      throw ArgumentError('Search limits and concurrency must be positive');
    }
    if (maximumDistance < 0 ||
        maximumDistance > differenceHashBitCount ||
        minimumDistanceGap < 0 ||
        minimumDistanceGap > differenceHashBitCount) {
      throw ArgumentError('dHash thresholds must be between 0 and 64');
    }
  }
}

class BookmarkVisualProgress {
  final BookmarkVisibility? visibility;
  final int pagesLoaded;
  final int worksScanned;
  final int imagesScheduled;
  final int imagesCompared;
  final int imageFailures;
  final int candidateCount;

  const BookmarkVisualProgress({
    this.visibility,
    this.pagesLoaded = 0,
    this.worksScanned = 0,
    this.imagesScheduled = 0,
    this.imagesCompared = 0,
    this.imageFailures = 0,
    this.candidateCount = 0,
  });

  BookmarkVisualProgress copyWith({
    BookmarkVisibility? visibility,
    int? pagesLoaded,
    int? worksScanned,
    int? imagesScheduled,
    int? imagesCompared,
    int? imageFailures,
    int? candidateCount,
  }) {
    return BookmarkVisualProgress(
      visibility: visibility ?? this.visibility,
      pagesLoaded: pagesLoaded ?? this.pagesLoaded,
      worksScanned: worksScanned ?? this.worksScanned,
      imagesScheduled: imagesScheduled ?? this.imagesScheduled,
      imagesCompared: imagesCompared ?? this.imagesCompared,
      imageFailures: imageFailures ?? this.imageFailures,
      candidateCount: candidateCount ?? this.candidateCount,
    );
  }
}

class BookmarkVisualCandidate {
  final int illustId;
  final int pageIndex;
  final BookmarkVisibility visibility;
  final BookmarkVisualMatchKind kind;
  final int? distance;
  final String imageUrl;

  const BookmarkVisualCandidate({
    required this.illustId,
    required this.pageIndex,
    required this.visibility,
    required this.kind,
    required this.distance,
    required this.imageUrl,
  });

  double? get similarity =>
      distance == null ? null : 1 - distance! / differenceHashBitCount;
}

class BookmarkVisualSearchResult {
  final BookmarkVisualSearchStatus status;
  final BookmarkVisualCandidate? match;
  final List<BookmarkVisualCandidate> candidates;
  final BookmarkVisualProgress progress;
  final bool scanComplete;
  final bool requiresConfirmation;
  final String? querySha256;
  final Object? error;
  final StackTrace? stackTrace;

  const BookmarkVisualSearchResult({
    required this.status,
    required this.candidates,
    required this.progress,
    this.match,
    this.scanComplete = false,
    this.requiresConfirmation = false,
    this.querySha256,
    this.error,
    this.stackTrace,
  });
}

class BookmarkVisualAuthorizationException implements Exception {
  final String message;

  const BookmarkVisualAuthorizationException(this.message);

  @override
  String toString() => 'BookmarkVisualAuthorizationException: $message';
}

typedef BookmarkVisualProgressCallback =
    void Function(BookmarkVisualProgress progress);

class BookmarkVisualSearchService {
  final CurrentUserBookmarkVisualSource source;
  final BookmarkVisualImageFetcher imageFetcher;
  final BookmarkVisualFingerprintComputer fingerprintComputer;
  final BookmarkVisualSearchLimits limits;
  final bool allowEarlyExactPerceptualMatch;

  BookmarkVisualSearchService({
    required this.source,
    required this.imageFetcher,
    required this.fingerprintComputer,
    this.limits = const BookmarkVisualSearchLimits(),
    this.allowEarlyExactPerceptualMatch = true,
  }) {
    limits.validate();
  }

  Future<BookmarkVisualSearchResult> search({
    required Uint8List queryBytes,
    String? queryFileName,
    BookmarkVisualCancellationToken? cancellationToken,
    BookmarkVisualProgressCallback? onProgress,
  }) async {
    final token = cancellationToken ?? BookmarkVisualCancellationToken();
    var progress = const BookmarkVisualProgress();
    final rawCandidates = <_RawCandidate>[];
    final seenWorks = <int>{};
    final seenImages = <String>{};
    var hitLimit = false;
    var stopAllForQuantityLimit = false;

    void emit() {
      if (onProgress == null) return;
      try {
        onProgress(progress);
      } on Object {
        // UI progress reporting must never terminate an authenticated search.
      }
    }

    if (queryBytes.isEmpty) {
      return BookmarkVisualSearchResult(
        status: BookmarkVisualSearchStatus.failed,
        candidates: const <BookmarkVisualCandidate>[],
        progress: progress,
        error: const FormatException('The query image is empty'),
      );
    }

    final expectedUserId = source.currentUserId;
    if (expectedUserId == null || expectedUserId <= 0) {
      return BookmarkVisualSearchResult(
        status: BookmarkVisualSearchStatus.unauthenticated,
        candidates: const <BookmarkVisualCandidate>[],
        progress: progress,
      );
    }

    late final BookmarkVisualFingerprint queryFingerprint;
    try {
      queryFingerprint = await fingerprintComputer.compute(queryBytes);
    } catch (error, stackTrace) {
      return BookmarkVisualSearchResult(
        status: BookmarkVisualSearchStatus.failed,
        candidates: const <BookmarkVisualCandidate>[],
        progress: progress,
        error: error,
        stackTrace: stackTrace,
      );
    }
    final queryDifferenceHash = queryFingerprint.differenceHash;
    if (queryDifferenceHash == null ||
        !isValidDifferenceHash(queryDifferenceHash)) {
      return BookmarkVisualSearchResult(
        status: BookmarkVisualSearchStatus.failed,
        candidates: const <BookmarkVisualCandidate>[],
        progress: progress,
        error: const FormatException(
          'The query image could not be decoded for visual comparison',
        ),
      );
    }

    try {
      final cursors = <BookmarkVisibility, _BookmarkPageCursor>{
        for (final visibility in BookmarkVisibility.values)
          visibility: _BookmarkPageCursor(),
      };

      roundRobinLoop:
      while (cursors.values.any((cursor) => !cursor.done)) {
        for (final visibility in BookmarkVisibility.values) {
          final cursor = cursors[visibility]!;
          if (cursor.done) continue;
          if (token.isCancelled) break roundRobinLoop;
          if (source.currentUserId != expectedUserId) {
            return _terminal(
              BookmarkVisualSearchStatus.accountChanged,
              rawCandidates,
              progress,
            );
          }
          if (cursor.pagesLoaded >= limits.maximumPagesPerVisibility) {
            cursor.done = true;
            hitLimit = true;
            continue;
          }
          if (!cursor.seenOffsets.add(cursor.offset)) {
            throw const FormatException(
              'Pixiv returned a repeated bookmark-page offset',
            );
          }

          final page = await source.loadPage(
            expectedUserId: expectedUserId,
            visibility: visibility,
            offset: cursor.offset,
            cancellationToken: token,
          );
          if (source.currentUserId != expectedUserId) {
            return _terminal(
              BookmarkVisualSearchStatus.accountChanged,
              rawCandidates,
              progress,
            );
          }
          cursor.pagesLoaded++;
          cursor.offset = page.nextOffset;
          cursor.done = page.nextOffset == null;
          progress = progress.copyWith(
            visibility: visibility,
            pagesLoaded: progress.pagesLoaded + 1,
          );
          emit();

          final jobs = <_ImageJob>[];
          for (final work in page.works) {
            if (work.illustId <= 0 || !seenWorks.add(work.illustId)) continue;
            if (progress.worksScanned >= limits.maximumWorks) {
              hitLimit = true;
              stopAllForQuantityLimit = true;
              break;
            }
            progress = progress.copyWith(
              worksScanned: progress.worksScanned + 1,
            );
            for (final image in work.images) {
              final imageKey = '${work.illustId}:${image.pageIndex}';
              if (image.pageIndex < 0 ||
                  image.url.isEmpty ||
                  !seenImages.add(imageKey)) {
                continue;
              }
              if (progress.imagesScheduled >= limits.maximumImages) {
                hitLimit = true;
                stopAllForQuantityLimit = true;
                break;
              }
              jobs.add(
                _ImageJob(work: work, image: image, visibility: visibility),
              );
              progress = progress.copyWith(
                imagesScheduled: progress.imagesScheduled + 1,
              );
            }
            if (stopAllForQuantityLimit) break;
          }

          await _forEachConcurrent<_ImageJob>(
            jobs,
            limits.downloadConcurrency,
            token,
            (job) async {
              if (token.isCancelled) return;
              try {
                final bytes = await imageFetcher.fetch(job.image, token);
                if (token.isCancelled) return;
                final fingerprint = await fingerprintComputer.compute(bytes);
                if (token.isCancelled) return;
                final exactBytes =
                    fingerprint.sha256.toLowerCase() ==
                    queryFingerprint.sha256.toLowerCase();
                int? distance;
                final queryHash = queryFingerprint.differenceHash;
                final candidateHash = fingerprint.differenceHash;
                if (queryHash != null &&
                    candidateHash != null &&
                    isValidDifferenceHash(queryHash) &&
                    isValidDifferenceHash(candidateHash)) {
                  distance = differenceHashDistance(queryHash, candidateHash);
                }
                if (!exactBytes && distance == null) {
                  progress = progress.copyWith(
                    imageFailures: progress.imageFailures + 1,
                  );
                  emit();
                  return;
                }
                if (exactBytes ||
                    (distance != null &&
                        distance <= _candidateCollectionMaximumDistance)) {
                  rawCandidates.add(
                    _RawCandidate(
                      illustId: job.work.illustId,
                      pageIndex: job.image.pageIndex,
                      visibility: job.visibility,
                      exactBytes: exactBytes,
                      distance: distance,
                      imageUrl: job.image.url,
                    ),
                  );
                }
                progress = progress.copyWith(
                  imagesCompared: progress.imagesCompared + 1,
                  candidateCount: rawCandidates.length,
                );
              } on Object {
                if (!token.isCancelled) {
                  progress = progress.copyWith(
                    imageFailures: progress.imageFailures + 1,
                  );
                }
              }
              emit();
            },
          );

          if (token.isCancelled) break roundRobinLoop;
          if (stopAllForQuantityLimit) break roundRobinLoop;
          final exactMatch = _uniqueExactBytes(rawCandidates);
          if (exactMatch != null) {
            return _provisionalMatch(
              exactMatch,
              rawCandidates,
              progress,
              queryFingerprint.sha256,
            );
          }
        }

        // A zero-distance dHash is still only a perceptual candidate. Check one
        // complete public/private round before returning it so a collision in
        // the first public page cannot hide the real private-page candidate.
        if (!token.isCancelled &&
            !stopAllForQuantityLimit &&
            !hitLimit &&
            allowEarlyExactPerceptualMatch) {
          final earlyMatch = _uniqueZeroDistance(rawCandidates);
          if (earlyMatch != null) {
            return _provisionalMatch(
              earlyMatch,
              rawCandidates,
              progress,
              queryFingerprint.sha256,
            );
          }
        }
      }
    } on BookmarkVisualAuthorizationException {
      return _terminal(
        BookmarkVisualSearchStatus.accountChanged,
        rawCandidates,
        progress,
      );
    } catch (error, stackTrace) {
      if (token.isCancelled) {
        return _terminal(
          BookmarkVisualSearchStatus.cancelled,
          rawCandidates,
          progress,
        );
      }
      return BookmarkVisualSearchResult(
        status: BookmarkVisualSearchStatus.failed,
        candidates: _rankCandidates(rawCandidates),
        progress: progress,
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (token.isCancelled) {
      return _terminal(
        BookmarkVisualSearchStatus.cancelled,
        rawCandidates,
        progress,
      );
    }
    if (hitLimit) {
      return _terminal(
        BookmarkVisualSearchStatus.limitReached,
        rawCandidates,
        progress,
      );
    }
    if (progress.imageFailures > 0) {
      return _terminal(
        BookmarkVisualSearchStatus.incomplete,
        rawCandidates,
        progress,
      );
    }

    final resolution = _resolve(rawCandidates);
    if (resolution.match == null) {
      return BookmarkVisualSearchResult(
        status: resolution.ambiguous
            ? BookmarkVisualSearchStatus.ambiguous
            : BookmarkVisualSearchStatus.notFound,
        candidates: resolution.candidates,
        progress: progress,
        scanComplete: true,
      );
    }

    return BookmarkVisualSearchResult(
      status: BookmarkVisualSearchStatus.matched,
      match: resolution.match,
      candidates: resolution.candidates,
      progress: progress,
      scanComplete: true,
      requiresConfirmation: true,
      querySha256: queryFingerprint.sha256,
    );
  }

  BookmarkVisualCandidate? _uniqueZeroDistance(
    List<_RawCandidate> rawCandidates,
  ) {
    final resolution = _resolve(rawCandidates);
    final match = resolution.match;
    return match != null && match.distance == 0 ? match : null;
  }

  BookmarkVisualCandidate? _uniqueExactBytes(
    List<_RawCandidate> rawCandidates,
  ) {
    final exact = _bestByWork(
      rawCandidates,
    ).values.where((candidate) => candidate.exactBytes).toList(growable: false);
    return exact.length == 1 ? _toCandidate(exact.single) : null;
  }

  BookmarkVisualSearchResult _provisionalMatch(
    BookmarkVisualCandidate match,
    List<_RawCandidate> rawCandidates,
    BookmarkVisualProgress progress,
    String querySha256,
  ) {
    return BookmarkVisualSearchResult(
      status: BookmarkVisualSearchStatus.matched,
      match: match,
      candidates: _rankCandidates(rawCandidates),
      progress: progress,
      requiresConfirmation: true,
      querySha256: querySha256,
    );
  }

  int get _candidateCollectionMaximumDistance => math.min(
    differenceHashBitCount,
    limits.maximumDistance + math.max(0, limits.minimumDistanceGap - 1),
  );

  BookmarkVisualSearchResult _terminal(
    BookmarkVisualSearchStatus status,
    List<_RawCandidate> rawCandidates,
    BookmarkVisualProgress progress,
  ) {
    return BookmarkVisualSearchResult(
      status: status,
      candidates: _rankCandidates(rawCandidates),
      progress: progress,
    );
  }

  _Resolution _resolve(List<_RawCandidate> rawCandidates) {
    final bestByWork = _bestByWork(rawCandidates);
    final candidates = _rankCandidates(bestByWork.values);
    final exact = bestByWork.values
        .where((candidate) => candidate.exactBytes)
        .toList(growable: false);
    if (exact.length == 1) {
      return _Resolution(
        match: _toCandidate(exact.single),
        candidates: candidates,
      );
    }
    if (exact.length > 1) {
      return _Resolution(candidates: candidates, ambiguous: true);
    }

    final perceptual =
        bestByWork.values
            .where((candidate) => candidate.distance != null)
            .toList()
          ..sort(_compareRawCandidates);
    if (perceptual.isEmpty) return _Resolution(candidates: candidates);
    final best = perceptual.first;
    if (best.distance! > limits.maximumDistance) {
      return _Resolution(candidates: candidates);
    }
    if (perceptual.length > 1 &&
        perceptual[1].distance! - best.distance! < limits.minimumDistanceGap) {
      return _Resolution(candidates: candidates, ambiguous: true);
    }
    return _Resolution(match: _toCandidate(best), candidates: candidates);
  }

  List<BookmarkVisualCandidate> _rankCandidates(
    Iterable<_RawCandidate> rawCandidates,
  ) {
    final bestByWork = _bestByWork(rawCandidates).values.toList()
      ..sort(_compareRawCandidates);
    return List<BookmarkVisualCandidate>.unmodifiable(
      bestByWork.map(_toCandidate),
    );
  }

  Map<int, _RawCandidate> _bestByWork(Iterable<_RawCandidate> rawCandidates) {
    final bestByWork = <int, _RawCandidate>{};
    for (final candidate in rawCandidates) {
      final previous = bestByWork[candidate.illustId];
      if (previous == null || _compareRawCandidates(candidate, previous) < 0) {
        bestByWork[candidate.illustId] = candidate;
      }
    }
    return bestByWork;
  }
}

/// Persists a match only after the caller has shown it and received explicit
/// user confirmation. The SHA check prevents confirming a result against a
/// different gallery selection.
class BookmarkVisualMatchConfirmer {
  final BookmarkVisualFingerprintComputer fingerprintComputer;
  final BookmarkVisualIdentitySink identitySink;

  const BookmarkVisualMatchConfirmer({
    required this.fingerprintComputer,
    required this.identitySink,
  });

  Future<bool> confirm({
    required BookmarkVisualSearchResult result,
    required Uint8List queryBytes,
    String? queryFileName,
  }) async {
    final match = result.match;
    final expectedSha256 = result.querySha256;
    if (result.status != BookmarkVisualSearchStatus.matched ||
        !result.requiresConfirmation ||
        match == null ||
        expectedSha256 == null) {
      return false;
    }
    final fingerprint = await fingerprintComputer.compute(queryBytes);
    if (fingerprint.sha256.toLowerCase() != expectedSha256.toLowerCase()) {
      return false;
    }
    await identitySink.remember(
      BookmarkVisualIndexRecord(
        sha256: fingerprint.sha256,
        differenceHash: fingerprint.differenceHash,
        illustId: match.illustId,
        pageIndex: match.pageIndex,
        fileName: queryFileName,
      ),
    );
    return true;
  }
}

class _BookmarkPageCursor {
  int pagesLoaded = 0;
  int? offset;
  bool done = false;
  final Set<int?> seenOffsets = <int?>{};
}

Future<void> _forEachConcurrent<T>(
  List<T> values,
  int concurrency,
  BookmarkVisualCancellationToken token,
  Future<void> Function(T value) action,
) async {
  if (values.isEmpty) return;
  var nextIndex = 0;

  Future<void> worker() async {
    while (!token.isCancelled) {
      final index = nextIndex++;
      if (index >= values.length) return;
      await action(values[index]);
    }
  }

  await Future.wait(
    List<Future<void>>.generate(
      math.min(concurrency, values.length),
      (_) => worker(),
      growable: false,
    ),
  );
}

int _compareRawCandidates(_RawCandidate first, _RawCandidate second) {
  if (first.exactBytes != second.exactBytes) {
    return first.exactBytes ? -1 : 1;
  }
  final distance = (first.distance ?? differenceHashBitCount + 1).compareTo(
    second.distance ?? differenceHashBitCount + 1,
  );
  if (distance != 0) return distance;
  final id = first.illustId.compareTo(second.illustId);
  if (id != 0) return id;
  return first.pageIndex.compareTo(second.pageIndex);
}

BookmarkVisualCandidate _toCandidate(_RawCandidate raw) {
  final kind = raw.exactBytes
      ? BookmarkVisualMatchKind.exactBytes
      : raw.distance == 0
      ? BookmarkVisualMatchKind.exactPerceptual
      : BookmarkVisualMatchKind.nearPerceptual;
  return BookmarkVisualCandidate(
    illustId: raw.illustId,
    pageIndex: raw.pageIndex,
    visibility: raw.visibility,
    kind: kind,
    distance: raw.distance,
    imageUrl: raw.imageUrl,
  );
}

class _ImageJob {
  final BookmarkVisualWork work;
  final BookmarkVisualImageReference image;
  final BookmarkVisibility visibility;

  const _ImageJob({
    required this.work,
    required this.image,
    required this.visibility,
  });
}

class _RawCandidate {
  final int illustId;
  final int pageIndex;
  final BookmarkVisibility visibility;
  final bool exactBytes;
  final int? distance;
  final String imageUrl;

  const _RawCandidate({
    required this.illustId,
    required this.pageIndex,
    required this.visibility,
    required this.exactBytes,
    required this.distance,
    required this.imageUrl,
  });
}

class _Resolution {
  final BookmarkVisualCandidate? match;
  final List<BookmarkVisualCandidate> candidates;
  final bool ambiguous;

  const _Resolution({
    this.match,
    required this.candidates,
    this.ambiguous = false,
  });
}
