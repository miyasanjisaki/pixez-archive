import 'dart:typed_data';

/// Maximum encoded size accepted for a user-selected reverse-search image.
///
/// The original bytes stay on-device. External providers receive a separately
/// decoded, metadata-free and resized JPEG prepared by the caller.
const int maximumReverseImageInputBytes = 52 * 1024 * 1024;

/// Returns whether a selected file has a non-empty encoded payload within the
/// on-device reverse-search limit.
///
/// This limit governs only the local source read. Providers still receive the
/// much smaller sanitized JPEG probe prepared later in the pipeline.
bool isReverseImageInputByteLengthAllowed(int byteLength) =>
    byteLength > 0 && byteLength <= maximumReverseImageInputBytes;

/// Validates a size reported before a document-provider stream is opened.
///
/// Android document providers may report zero when the length is not known
/// yet. The completed read is validated separately with
/// [isReverseImageInputByteLengthAllowed], so zero is allowed only here.
bool isReverseImageReportedByteLengthAllowed(int byteLength) =>
    byteLength >= 0 && byteLength <= maximumReverseImageInputBytes;

/// A provider-independent query transformation.
///
/// [center], [left], [right], [top] and [bottom] crop the selected input to a
/// subject region. [inputTopHalf] and [inputBottomHalf] have deliberately
/// different semantics: the selected input is already a half image, so every
/// source pixel is retained and the missing half is represented by padding.
enum ReverseImageProbeKind {
  full,
  center,
  left,
  right,
  top,
  bottom,
  inputTopHalf,
  inputBottomHalf,
}

extension ReverseImageProbeKindProperties on ReverseImageProbeKind {
  bool get isHalfImageInput =>
      this == ReverseImageProbeKind.inputTopHalf ||
      this == ReverseImageProbeKind.inputBottomHalf;
}

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

/// Pure geometry for preparing one external-search probe.
///
/// The source rectangle is expressed in selected-image pixels. Canvas and
/// destination coordinates describe the logical pre-resize composition, while
/// the output fields describe the bounded JPEG dimensions actually allocated.
/// Keeping this planning separate makes it testable that half-image probes do
/// not accidentally pass through the crop path.
class ReverseImageProbeLayout {
  final ReverseImageProbeKind kind;
  final ReverseImageProbeRegion source;
  final int canvasWidth;
  final int canvasHeight;
  final int destinationX;
  final int destinationY;
  final int outputWidth;
  final int outputHeight;
  final int outputContentWidth;
  final int outputContentHeight;
  final int outputDestinationX;
  final int outputDestinationY;

  const ReverseImageProbeLayout({
    required this.kind,
    required this.source,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.destinationX,
    required this.destinationY,
    required this.outputWidth,
    required this.outputHeight,
    required this.outputContentWidth,
    required this.outputContentHeight,
    required this.outputDestinationX,
    required this.outputDestinationY,
  });

  bool get preservesWholeInput =>
      kind == ReverseImageProbeKind.full || kind.isHalfImageInput;
}

/// Plans either a subject crop or a missing-half canvas without decoding.
///
/// A half-image input is placed unchanged in the corresponding half of a
/// double-height logical canvas. The returned output geometry is already
/// bounded, so callers can resize the source first and avoid allocating a
/// potentially 64-megapixel intermediate canvas.
ReverseImageProbeLayout planReverseImageProbeLayout(
  int width,
  int height,
  ReverseImageProbeKind kind, {
  int maximumOutputDimension = 1600,
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('Image dimensions must be positive');
  }
  if (maximumOutputDimension < 2) {
    throw ArgumentError.value(
      maximumOutputDimension,
      'maximumOutputDimension',
      'must be at least 2',
    );
  }

  late final ReverseImageProbeRegion source;
  late final int canvasWidth;
  late final int canvasHeight;
  late final int destinationY;
  if (kind.isHalfImageInput) {
    source = ReverseImageProbeRegion(
      kind: kind,
      x: 0,
      y: 0,
      width: width,
      height: height,
    );
    canvasWidth = width;
    canvasHeight = height * 2;
    destinationY = kind == ReverseImageProbeKind.inputTopHalf ? 0 : height;
  } else {
    source = planReverseImageProbeRegions(
      width,
      height,
    ).singleWhere((region) => region.kind == kind);
    canvasWidth = source.width;
    canvasHeight = source.height;
    destinationY = 0;
  }

  final longestSide = canvasWidth > canvasHeight ? canvasWidth : canvasHeight;
  int bounded(int dimension) => longestSide <= maximumOutputDimension
      ? dimension
      : (dimension * maximumOutputDimension / longestSide)
            .round()
            .clamp(1, maximumOutputDimension)
            .toInt();

  final outputWidth = bounded(canvasWidth);
  var outputHeight = bounded(canvasHeight);
  if (kind.isHalfImageInput && outputHeight < 2) {
    // Both the supplied and missing halves must remain represented even for an
    // extremely wide input. Two pixels is still within the declared bound.
    outputHeight = 2;
  }
  final outputContentWidth = kind.isHalfImageInput
      ? outputWidth
      : bounded(source.width);
  final outputContentHeight = kind.isHalfImageInput
      ? (outputHeight / 2).round().clamp(1, outputHeight - 1).toInt()
      : bounded(source.height);
  final outputDestinationY = switch (kind) {
    ReverseImageProbeKind.inputBottomHalf => outputHeight - outputContentHeight,
    _ => 0,
  };

  return ReverseImageProbeLayout(
    kind: kind,
    source: source,
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
    destinationX: 0,
    destinationY: destinationY,
    outputWidth: outputWidth,
    outputHeight: outputHeight,
    outputContentWidth: outputContentWidth,
    outputContentHeight: outputContentHeight,
    outputDestinationX: 0,
    outputDestinationY: outputDestinationY,
  );
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
  final String? thumbnailUrl;

  const ReverseImageProviderHit({
    required this.providerId,
    required this.probe,
    required this.illustId,
    required this.similarity,
    required this.sourceUrl,
    this.title,
    this.thumbnailUrl,
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
