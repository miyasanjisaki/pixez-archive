import 'dart:typed_data';

import 'package:pixez/utils/pixiv_image_identity.dart';

const int defaultBackfillMaximumCandidates = 4096;
const int defaultBackfillMaximumImageBytes = 64 * 1024 * 1024;

/// A saved image exposed by the platform layer without loading its bytes yet.
///
/// [token] is intentionally opaque. Android can use either an absolute path or
/// a persisted document URI while the planner only inspects the safe textual
/// hints needed to recover a Pixiv source identity.
class SavedImageBackfillReference {
  final String token;
  final String displayName;
  final String? relativePath;
  final int? byteLength;

  const SavedImageBackfillReference({
    required this.token,
    required this.displayName,
    this.relativePath,
    this.byteLength,
  });
}

/// Minimal, platform-agnostic projection of a completed row from `task1.db`.
/// The caller must exclude queued, failed, and cancelled tasks.
class CompletedDownloadBackfillReference {
  final int illustId;
  final String fileName;
  final String sourceUrl;

  const CompletedDownloadBackfillReference({
    required this.illustId,
    required this.fileName,
    required this.sourceUrl,
  });
}

enum DownloadIdentityBackfillEvidence {
  canonicalFileName,
  completedDownloadTask,
  canonicalFileNameAndTask,
}

class DownloadIdentityBackfillCandidate {
  final SavedImageBackfillReference image;
  final int illustId;
  final int pageIndex;
  final DownloadIdentityBackfillEvidence evidence;

  const DownloadIdentityBackfillCandidate({
    required this.image,
    required this.illustId,
    required this.pageIndex,
    required this.evidence,
  });
}

class DownloadIdentityBackfillPlan {
  final List<DownloadIdentityBackfillCandidate> candidates;
  final int unidentifiedCount;
  final int ambiguousCount;
  final int oversizedCount;
  final int duplicateTokenCount;
  final bool truncated;

  const DownloadIdentityBackfillPlan({
    required this.candidates,
    required this.unidentifiedCount,
    required this.ambiguousCount,
    required this.oversizedCount,
    required this.duplicateTokenCount,
    required this.truncated,
  });
}

/// Builds a conservative, bounded plan for indexing images downloaded before
/// the local SHA/dHash index was introduced.
///
/// A candidate is accepted only when its canonical Pixiv filename and every
/// matching completed download task agree. Conflicting IDs or page numbers are
/// skipped instead of guessing. No image bytes, network requests, or database
/// writes happen while planning.
DownloadIdentityBackfillPlan planDownloadIdentityBackfill({
  required Iterable<SavedImageBackfillReference> savedImages,
  required Iterable<CompletedDownloadBackfillReference> completedDownloads,
  int maximumCandidates = defaultBackfillMaximumCandidates,
  int maximumImageBytes = defaultBackfillMaximumImageBytes,
  bool sourceTruncated = false,
}) {
  if (maximumCandidates <= 0) {
    throw ArgumentError.value(
      maximumCandidates,
      'maximumCandidates',
      'must be greater than zero',
    );
  }
  if (maximumImageBytes <= 0) {
    throw ArgumentError.value(
      maximumImageBytes,
      'maximumImageBytes',
      'must be greater than zero',
    );
  }

  final completedTasks = completedDownloads
      .where((task) => task.illustId > 0)
      .toList(growable: false);
  final tasksByBaseName = <String, List<CompletedDownloadBackfillReference>>{};
  for (final task in completedTasks) {
    final taskName = _normalizeDownloadedImageName(task.fileName);
    if (taskName.isEmpty) continue;
    (tasksByBaseName[taskName] ??= <CompletedDownloadBackfillReference>[]).add(
      task,
    );
  }

  final candidates = <DownloadIdentityBackfillCandidate>[];
  final seenTokens = <String>{};
  var unidentifiedCount = 0;
  var ambiguousCount = 0;
  var oversizedCount = 0;
  var duplicateTokenCount = 0;
  var truncated = sourceTruncated;

  for (final image in savedImages) {
    final token = image.token.trim();
    if (token.isEmpty || !seenTokens.add(token)) {
      duplicateTokenCount++;
      continue;
    }
    final byteLength = image.byteLength;
    if (byteLength != null &&
        (byteLength <= 0 || byteLength > maximumImageBytes)) {
      oversizedCount++;
      continue;
    }

    final imageHints = <String?>[
      image.displayName,
      image.relativePath,
      image.token,
    ];
    final idsFromImage = imageHints
        .whereType<String>()
        .expand(extractPixivIllustIdsFromText)
        .toSet();
    if (idsFromImage.length > 1) {
      ambiguousCount++;
      continue;
    }

    final normalizedName = _normalizeDownloadedImageName(image.displayName);
    final matchingTasks = <CompletedDownloadBackfillReference>{
      ...?tasksByBaseName[normalizedName],
    }.toList(growable: false);
    final taskIds = matchingTasks.map((task) => task.illustId).toSet();
    if (taskIds.length > 1) {
      ambiguousCount++;
      continue;
    }

    final imageId = idsFromImage.firstOrNull;
    final taskId = taskIds.firstOrNull;
    if (imageId != null && taskId != null && imageId != taskId) {
      ambiguousCount++;
      continue;
    }
    final illustId = imageId ?? taskId;
    if (illustId == null) {
      unidentifiedCount++;
      continue;
    }

    final pageIndexes = <int>{};
    for (final hint in imageHints) {
      final pageIndex = extractPixivPageIndex(hints: <String?>[hint]);
      if (pageIndex != null) pageIndexes.add(pageIndex);
    }
    for (final task in matchingTasks.where(
      (task) => task.illustId == illustId,
    )) {
      final pageIndex = extractPixivPageIndex(
        hints: <String?>[task.fileName, task.sourceUrl],
      );
      if (pageIndex != null) pageIndexes.add(pageIndex);
    }
    if (pageIndexes.length > 1) {
      ambiguousCount++;
      continue;
    }

    if (candidates.length >= maximumCandidates) {
      truncated = true;
      continue;
    }
    candidates.add(
      DownloadIdentityBackfillCandidate(
        image: image,
        illustId: illustId,
        pageIndex: pageIndexes.firstOrNull ?? 0,
        evidence: imageId != null && taskId != null
            ? DownloadIdentityBackfillEvidence.canonicalFileNameAndTask
            : imageId != null
            ? DownloadIdentityBackfillEvidence.canonicalFileName
            : DownloadIdentityBackfillEvidence.completedDownloadTask,
      ),
    );
  }

  return DownloadIdentityBackfillPlan(
    candidates: List.unmodifiable(candidates),
    unidentifiedCount: unidentifiedCount,
    ambiguousCount: ambiguousCount,
    oversizedCount: oversizedCount,
    duplicateTokenCount: duplicateTokenCount,
    truncated: truncated,
  );
}

String _normalizeDownloadedImageName(String value) {
  var candidate = value.trim();
  final queryName =
      _rawQueryValue(candidate, 'displayName') ??
      _rawQueryValue(candidate, 'name');
  if (queryName != null) {
    candidate = _decodeUriName(queryName, plusAsSpace: true);
  } else {
    final uri = Uri.tryParse(candidate);
    try {
      if (uri != null && uri.pathSegments.isNotEmpty) {
        candidate = uri.pathSegments.last;
      } else {
        candidate = _decodeUriName(candidate);
      }
    } on FormatException {
      candidate = _decodeUriName(candidate);
    } on ArgumentError {
      candidate = _decodeUriName(candidate);
    }
  }
  return candidate.replaceAll('\\', '/').split('/').last.trim().toLowerCase();
}

String? _rawQueryValue(String value, String key) => RegExp(
  '(?:[?&])${RegExp.escape(key)}=([^&#]*)',
  caseSensitive: false,
).firstMatch(value)?.group(1);

String _decodeUriName(String value, {bool plusAsSpace = false}) {
  final candidate = plusAsSpace ? value.replaceAll('+', ' ') : value;
  try {
    return Uri.decodeComponent(candidate);
  } on FormatException {
    return candidate;
  } on ArgumentError {
    return candidate;
  }
}

typedef BackfillImageReader =
    Future<Uint8List?> Function(SavedImageBackfillReference image);
typedef BackfillFingerprintComputer =
    Future<Map<String, String?>> Function(Uint8List bytes);
typedef BackfillIdentityWriter =
    Future<bool> Function(
      DownloadIdentityBackfillCandidate candidate,
      Map<String, String?> fingerprints,
    );
typedef BackfillAbortOnError = bool Function(Object error);

class DownloadIdentityBackfillProgress {
  final int total;
  final int processed;
  final int indexed;
  final int skipped;
  final int failed;
  final String? currentDisplayName;

  const DownloadIdentityBackfillProgress({
    required this.total,
    required this.processed,
    required this.indexed,
    required this.skipped,
    required this.failed,
    required this.currentDisplayName,
  });
}

class DownloadIdentityBackfillRunSummary {
  final int total;
  final int processed;
  final int indexed;
  final int skipped;
  final int failed;
  final bool cancelled;

  const DownloadIdentityBackfillRunSummary({
    required this.total,
    required this.processed,
    required this.indexed,
    required this.skipped,
    required this.failed,
    required this.cancelled,
  });
}

/// Executes a pre-built plan sequentially so callers can expose useful
/// progress and cancel between files. Fingerprinting is injected so Flutter UI
/// code can run it with `compute` instead of blocking the UI isolate.
Future<DownloadIdentityBackfillRunSummary> runDownloadIdentityBackfill({
  required DownloadIdentityBackfillPlan plan,
  required BackfillImageReader readImage,
  required BackfillFingerprintComputer computeFingerprints,
  required BackfillIdentityWriter rememberIdentity,
  int maximumImageBytes = defaultBackfillMaximumImageBytes,
  bool Function()? shouldCancel,
  BackfillAbortOnError? abortOnError,
  void Function(DownloadIdentityBackfillProgress progress)? onProgress,
}) async {
  if (maximumImageBytes <= 0) {
    throw ArgumentError.value(
      maximumImageBytes,
      'maximumImageBytes',
      'must be greater than zero',
    );
  }

  final total = plan.candidates.length;
  var processed = 0;
  var indexed = 0;
  var skipped = 0;
  var failed = 0;
  var cancelled = false;

  for (final candidate in plan.candidates) {
    if (shouldCancel?.call() == true) {
      cancelled = true;
      break;
    }

    try {
      final bytes = await readImage(candidate.image);
      if (shouldCancel?.call() == true) {
        cancelled = true;
        break;
      }
      if (bytes == null || bytes.isEmpty || bytes.length > maximumImageBytes) {
        skipped++;
      } else {
        final fingerprints = await computeFingerprints(bytes);
        final sha256 = fingerprints['sha256'];
        if (!_isSha256(sha256)) {
          failed++;
        } else {
          final remembered = await rememberIdentity(candidate, fingerprints);
          if (remembered) {
            indexed++;
          } else {
            skipped++;
          }
        }
      }
    } catch (error) {
      if (abortOnError?.call(error) == true) rethrow;
      // One inaccessible/corrupt file must not abort a user-started batch.
      failed++;
    }
    processed++;
    onProgress?.call(
      DownloadIdentityBackfillProgress(
        total: total,
        processed: processed,
        indexed: indexed,
        skipped: skipped,
        failed: failed,
        currentDisplayName: candidate.image.displayName,
      ),
    );
  }

  return DownloadIdentityBackfillRunSummary(
    total: total,
    processed: processed,
    indexed: indexed,
    skipped: skipped,
    failed: failed,
    cancelled: cancelled,
  );
}

bool _isSha256(String? value) =>
    value != null &&
    RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(value);

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
