import 'dart:typed_data';

/// A provider-independent query region. Coordinates are expressed in source
/// image pixels so encoding can happen once, outside the UI layer.
enum ReverseImageProbeKind { full, center, left, right, top, bottom }

class ReverseImageProbeRegion {
  final ReverseImageProbeKind kind;
  final int x;
  final int y;
  final int width;
  final int height;

  const ReverseImageProbeRegion({
    required this.kind,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

/// Builds overlapping regions for an explicit deep search.
///
/// The 70% side probes deliberately keep substantial overlap. They are meant
/// to isolate a single illustration from borders, UI chrome, or a two-image
/// collage; they cannot reconstruct pixels that are already missing from the
/// selected file. The caller must enforce provider quotas and should not send
/// every region automatically.
List<ReverseImageProbeRegion> planReverseImageProbeRegions(
  int width,
  int height, {
  double sideFraction = 0.70,
  double centerFraction = 0.84,
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('Image dimensions must be positive');
  }
  if (sideFraction <= 0.5 || sideFraction > 1) {
    throw ArgumentError.value(
      sideFraction,
      'sideFraction',
      'must be greater than 0.5 and at most 1',
    );
  }
  if (centerFraction <= 0.5 || centerFraction > 1) {
    throw ArgumentError.value(
      centerFraction,
      'centerFraction',
      'must be greater than 0.5 and at most 1',
    );
  }

  int scaled(int value, double fraction) =>
      (value * fraction).round().clamp(1, value);

  final centerWidth = scaled(width, centerFraction);
  final centerHeight = scaled(height, centerFraction);
  final sideWidth = scaled(width, sideFraction);
  final sideHeight = scaled(height, sideFraction);

  return <ReverseImageProbeRegion>[
    ReverseImageProbeRegion(
      kind: ReverseImageProbeKind.full,
      x: 0,
      y: 0,
      width: width,
      height: height,
    ),
    ReverseImageProbeRegion(
      kind: ReverseImageProbeKind.center,
      x: (width - centerWidth) ~/ 2,
      y: (height - centerHeight) ~/ 2,
      width: centerWidth,
      height: centerHeight,
    ),
    ReverseImageProbeRegion(
      kind: ReverseImageProbeKind.left,
      x: 0,
      y: 0,
      width: sideWidth,
      height: height,
    ),
    ReverseImageProbeRegion(
      kind: ReverseImageProbeKind.right,
      x: width - sideWidth,
      y: 0,
      width: sideWidth,
      height: height,
    ),
    ReverseImageProbeRegion(
      kind: ReverseImageProbeKind.top,
      x: 0,
      y: 0,
      width: width,
      height: sideHeight,
    ),
    ReverseImageProbeRegion(
      kind: ReverseImageProbeKind.bottom,
      x: 0,
      y: height - sideHeight,
      width: width,
      height: sideHeight,
    ),
  ];
}

class ReverseImageQuery {
  final Uint8List bytes;
  final String extension;
  final ReverseImageProbeKind probe;

  const ReverseImageQuery({
    required this.bytes,
    required this.extension,
    required this.probe,
  });
}

class ReverseImageProviderHit {
  final String providerId;
  final ReverseImageProbeKind probe;
  final int? illustId;
  final double similarity;
  final String sourceUrl;
  final String? title;

  const ReverseImageProviderHit({
    required this.providerId,
    required this.probe,
    required this.illustId,
    required this.similarity,
    required this.sourceUrl,
    this.title,
  });
}

class ReverseImageProviderResponse {
  final List<ReverseImageProviderHit> hits;
  final bool rateLimited;
  final String? serviceMessage;

  const ReverseImageProviderResponse({
    this.hits = const [],
    this.rateLimited = false,
    this.serviceMessage,
  });
}

/// Contract for services that expose a documented, permitted integration.
/// Providers backed only by a human-facing form should use a browser handoff
/// instead of pretending that screen-scraping is a stable API.
abstract interface class ReverseImageSearchProvider {
  String get id;

  Future<ReverseImageProviderResponse> search(ReverseImageQuery query);
}

class ReverseImageProviderRun {
  final List<ReverseImageProviderHit> hits;
  final int successfulProviders;
  final List<String> serviceMessages;

  const ReverseImageProviderRun({
    required this.hits,
    required this.successfulProviders,
    required this.serviceMessages,
  });

  bool get allProvidersFailed =>
      successfulProviders == 0 && serviceMessages.isNotEmpty;
}

/// Runs independent providers sequentially so a challenge, quota response, or
/// transport failure from one service does not abort the remaining providers.
Future<ReverseImageProviderRun> runReverseImageProviders(
  Iterable<ReverseImageSearchProvider> providers,
  ReverseImageQuery query,
) async {
  final hits = <ReverseImageProviderHit>[];
  final messages = <String>[];
  var successfulProviders = 0;
  for (final provider in providers) {
    try {
      final response = await provider.search(query);
      hits.addAll(response.hits);
      final message = response.serviceMessage;
      if (message == null) {
        successfulProviders++;
      } else {
        messages.add('${provider.id}: $message');
      }
    } catch (error) {
      messages.add('${provider.id}: $error');
    }
  }
  return ReverseImageProviderRun(
    hits: List.unmodifiable(hits),
    successfulProviders: successfulProviders,
    serviceMessages: List.unmodifiable(messages),
  );
}

class ReverseImageAggregatedCandidate {
  final int illustId;
  final double bestSimilarity;
  final double rankScore;
  final int probeHitCount;
  final int providerHitCount;
  final List<ReverseImageProviderHit> evidence;

  const ReverseImageAggregatedCandidate({
    required this.illustId,
    required this.bestSimilarity,
    required this.rankScore,
    required this.probeHitCount,
    required this.providerHitCount,
    required this.evidence,
  });

  /// Agreement boosts ordering only. It never turns a weak match into an
  /// automatic navigation decision.
  bool get canAutoOpen => bestSimilarity >= 80;
}

/// Returns a high-confidence winner only when it is not effectively tied with
/// another Pixiv candidate. Similarity values come from third parties, so a
/// close runner-up must be shown for human confirmation instead of silently
/// navigating to the first item.
ReverseImageAggregatedCandidate? chooseReverseImageAutoOpenCandidate(
  List<ReverseImageAggregatedCandidate> candidates, {
  double minimumMargin = 5,
  double? strongestExternalSimilarity,
}) {
  if (minimumMargin < 0 || !minimumMargin.isFinite) {
    throw ArgumentError.value(minimumMargin, 'minimumMargin');
  }
  if (candidates.isEmpty || !candidates.first.canAutoOpen) return null;
  if (candidates.length > 1 &&
      candidates.first.bestSimilarity - candidates[1].bestSimilarity <
          minimumMargin) {
    return null;
  }
  if (strongestExternalSimilarity != null) {
    if (!strongestExternalSimilarity.isFinite ||
        strongestExternalSimilarity < 0 ||
        strongestExternalSimilarity > 100) {
      throw ArgumentError.value(
        strongestExternalSimilarity,
        'strongestExternalSimilarity',
      );
    }
    if (candidates.first.bestSimilarity - strongestExternalSimilarity <
        minimumMargin) {
      return null;
    }
  }
  return candidates.first;
}

/// Merges repeated hits without conflating the ranking score with a provider's
/// reported similarity. A weak hit is retained only if a second independent
/// probe/provider agrees on the same Pixiv work.
List<ReverseImageAggregatedCandidate> aggregateReverseImageHits(
  Iterable<ReverseImageProviderHit> hits, {
  double minimumSingleSimilarity = 45,
  double minimumRepeatedSimilarity = 35,
}) {
  final byId = <int, List<ReverseImageProviderHit>>{};
  for (final hit in hits) {
    final illustId = hit.illustId;
    if (illustId == null ||
        illustId <= 0 ||
        !hit.similarity.isFinite ||
        hit.similarity < 0 ||
        hit.similarity > 100) {
      continue;
    }
    byId.putIfAbsent(illustId, () => []).add(hit);
  }

  final aggregated = <ReverseImageAggregatedCandidate>[];
  for (final entry in byId.entries) {
    final evidence = entry.value
      ..sort((a, b) => b.similarity.compareTo(a.similarity));
    final probes = evidence.map((hit) => hit.probe).toSet();
    final providers = evidence.map((hit) => hit.providerId).toSet();
    final best = evidence.first.similarity;
    final hasIndependentAgreement = probes.length >= 2 || providers.length >= 2;
    if (best < minimumSingleSimilarity &&
        !(hasIndependentAgreement && best >= minimumRepeatedSimilarity)) {
      continue;
    }

    final agreementBoost =
        ((probes.length - 1) * 4 + (providers.length - 1) * 3).clamp(0, 12);
    aggregated.add(
      ReverseImageAggregatedCandidate(
        illustId: entry.key,
        bestSimilarity: best,
        rankScore: (best + agreementBoost).clamp(0, 100),
        probeHitCount: probes.length,
        providerHitCount: providers.length,
        evidence: List.unmodifiable(evidence),
      ),
    );
  }

  aggregated.sort((a, b) {
    final byRank = b.rankScore.compareTo(a.rankScore);
    if (byRank != 0) return byRank;
    final byBest = b.bestSimilarity.compareTo(a.bestSimilarity);
    if (byBest != 0) return byBest;
    return a.illustId.compareTo(b.illustId);
  });
  return aggregated;
}
