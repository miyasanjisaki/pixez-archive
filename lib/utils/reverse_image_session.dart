import 'package:pixez/utils/reverse_image_search.dart';

enum ReverseImageSessionStepId {
  pick,
  localIdentity,
  bookmarks,
  prepare,
  sauceNao,
  iqdb,
  results,
  crop,
}

enum ReverseImageSessionStepState {
  pending,
  running,
  succeeded,
  noMatch,
  failed,
  skipped,
  cancelled,
}

class ReverseImageSessionStep {
  final ReverseImageSessionStepId id;
  final ReverseImageSessionStepState state;
  final String? detail;
  final DateTime? startedAt;
  final DateTime? endedAt;

  const ReverseImageSessionStep({
    required this.id,
    required this.state,
    this.detail,
    this.startedAt,
    this.endedAt,
  });

  Duration? get elapsed {
    final start = startedAt;
    if (start == null) return null;
    return (endedAt ?? DateTime.now()).difference(start);
  }

  ReverseImageSessionStep copyWith({
    ReverseImageSessionStepState? state,
    String? detail,
    bool clearDetail = false,
    DateTime? startedAt,
    DateTime? endedAt,
    bool clearEndedAt = false,
  }) {
    return ReverseImageSessionStep(
      id: id,
      state: state ?? this.state,
      detail: clearDetail ? null : detail ?? this.detail,
      startedAt: startedAt ?? this.startedAt,
      endedAt: clearEndedAt ? null : endedAt ?? this.endedAt,
    );
  }
}

enum ReverseImageCandidateConfidence { high, medium, low }

class ReverseImageDisplayCandidate {
  final int? illustId;
  final String sourceUrl;
  final String? title;
  final String? thumbnailUrl;
  final double bestSimilarity;
  final double rankScore;
  final List<ReverseImageProviderHit> evidence;

  const ReverseImageDisplayCandidate({
    required this.illustId,
    required this.sourceUrl,
    required this.title,
    required this.thumbnailUrl,
    required this.bestSimilarity,
    required this.rankScore,
    required this.evidence,
  });

  bool get isPixiv => illustId != null;

  String get candidateId =>
      illustId == null ? 'url:$sourceUrl' : 'pixiv:$illustId';

  ReverseImageCandidateConfidence get confidence {
    if (bestSimilarity >= 80) return ReverseImageCandidateConfidence.high;
    if (bestSimilarity >= 60) return ReverseImageCandidateConfidence.medium;
    return ReverseImageCandidateConfidence.low;
  }

  Set<String> get providerIds => evidence
      .map((hit) => hit.providerId)
      .where((value) => value.isNotEmpty)
      .toSet();

  Set<ReverseImageProbeKind> get probes =>
      evidence.map((hit) => hit.probe).toSet();
}

/// Produces the complete, stable candidate list shown by the image-search page.
///
/// Unlike the old modal dialog this does not truncate to five rows. A weak
/// Pixiv candidate is retained only when another provider or crop agrees;
/// confidence is shown to the user and no candidate is opened automatically.
List<ReverseImageDisplayCandidate> buildReverseImageDisplayCandidates(
  Iterable<ReverseImageProviderHit> hits,
) {
  final grouped = <String, List<ReverseImageProviderHit>>{};
  for (final hit in hits) {
    if (!hit.similarity.isFinite ||
        hit.similarity < 0 ||
        hit.similarity > 100 ||
        hit.sourceUrl.trim().isEmpty) {
      continue;
    }
    final key = hit.illustId == null
        ? 'url:${hit.sourceUrl.trim()}'
        : 'pixiv:${hit.illustId}';
    grouped.putIfAbsent(key, () => <ReverseImageProviderHit>[]).add(hit);
  }

  final aggregatedById = <int, ReverseImageAggregatedCandidate>{
    for (final candidate in aggregateReverseImageHits(hits))
      candidate.illustId: candidate,
  };
  final result = <ReverseImageDisplayCandidate>[];
  for (final evidence in grouped.values) {
    evidence.sort((left, right) {
      final similarity = right.similarity.compareTo(left.similarity);
      if (similarity != 0) return similarity;
      return left.providerId.compareTo(right.providerId);
    });
    final best = evidence.first;
    final aggregated = best.illustId == null
        ? null
        : aggregatedById[best.illustId];
    if (best.similarity < 45 && aggregated == null) {
      continue;
    }
    String? firstNonEmpty(Iterable<String?> values) {
      for (final value in values) {
        final trimmed = value?.trim();
        if (trimmed != null && trimmed.isNotEmpty) return trimmed;
      }
      return null;
    }

    result.add(
      ReverseImageDisplayCandidate(
        illustId: best.illustId,
        sourceUrl: best.sourceUrl,
        title: best.illustId == null
            ? firstNonEmpty(evidence.map((hit) => hit.title))
            : 'Pixiv #${best.illustId}',
        thumbnailUrl: firstNonEmpty(evidence.map((hit) => hit.thumbnailUrl)),
        bestSimilarity: best.similarity,
        rankScore: aggregated?.rankScore ?? best.similarity,
        evidence: List.unmodifiable(evidence),
      ),
    );
  }

  result.sort((left, right) {
    final score = right.rankScore.compareTo(left.rankScore);
    if (score != 0) return score;
    final similarity = right.bestSimilarity.compareTo(left.bestSimilarity);
    if (similarity != 0) return similarity;
    final leftKey = left.illustId?.toString() ?? left.sourceUrl;
    final rightKey = right.illustId?.toString() ?? right.sourceUrl;
    return leftKey.compareTo(rightKey);
  });
  return List.unmodifiable(result);
}
