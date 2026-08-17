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

/// Extracts a display-only Pixiv preview from an illustration-detail response.
/// The API response is still treated as untrusted data: only Pixiv's canonical
/// HTTPS image host is accepted before the URL reaches the image widget.
String? extractPixivCandidateThumbnailUrl(Object? responseData) {
  if (responseData is! Map) return null;
  final illust = responseData['illust'];
  if (illust is! Map) return null;
  // The detail response's top-level image URL is p0. Without a page index in
  // the reverse-search evidence it is only safe to upgrade single-page works;
  // multi-page matches keep the provider thumbnail for the actual hit page.
  final pageCount = illust['page_count'];
  if (pageCount is! num || pageCount.toInt() != 1) return null;
  final imageUrls = illust['image_urls'];
  if (imageUrls is! Map) return null;
  for (final key in const <String>['square_medium', 'medium']) {
    final value = imageUrls[key];
    if (value is! String) continue;
    final uri = Uri.tryParse(value);
    if (uri != null &&
        uri.scheme.toLowerCase() == 'https' &&
        uri.userInfo.isEmpty &&
        (!uri.hasPort || uri.port == 443) &&
        uri.host.toLowerCase() == 'i.pximg.net') {
      return value;
    }
  }
  return null;
}

/// Produces the complete, stable candidate list shown by the image-search page.
///
/// Unlike the old modal dialog this does not truncate to five rows. Every
/// provider-validated result is shown so the service's result count cannot
/// disagree with an apparently empty page. Weak results remain display-only:
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
    // SauceNAO's parser has already required an explicit Pixiv identity and a
    // minimum similarity for Pixiv hits. Keep those weak hits visible so a
    // completed provider cannot report N results while the page silently shows
    // none. Generic URLs still require the stricter 45% display threshold.
    if (best.illustId == null && best.similarity < 45 && aggregated == null) {
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
