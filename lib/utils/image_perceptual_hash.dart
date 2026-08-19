import 'dart:typed_data';

import 'package:image/image.dart' as image;

const int differenceHashBitCount = 64;
const int differenceHashHexLength = differenceHashBitCount ~/ 4;
const int defaultMaximumPerceptualHashPixels = 32 * 1024 * 1024;
const int defaultMaximumPerceptualHashBytes = 64 * 1024 * 1024;

/// Best-effort, bounded dHash computation for background indexing.
///
/// Exact SHA-256 indexing can still succeed when this returns `null`, for
/// example for an unsupported format or an image too large to decode safely.
String? tryComputeDifferenceHash(
  Uint8List encodedBytes, {
  int maximumDecodedPixels = defaultMaximumPerceptualHashPixels,
  int maximumEncodedBytes = defaultMaximumPerceptualHashBytes,
}) {
  if (maximumDecodedPixels <= 0 || maximumEncodedBytes <= 0) {
    throw ArgumentError('Hash size bounds must be positive');
  }
  if (encodedBytes.isEmpty || encodedBytes.length > maximumEncodedBytes) {
    return null;
  }
  try {
    final decoder = image.findDecoderForData(encodedBytes);
    final info = decoder?.startDecode(encodedBytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width > maximumDecodedPixels ~/ info.height) {
      return null;
    }
    return computeDifferenceHash(encodedBytes);
  } on FormatException {
    return null;
  } on RangeError {
    return null;
  } on StateError {
    return null;
  } on Exception {
    return null;
  }
}

/// Computes a 64-bit difference hash (dHash) from encoded image bytes.
///
/// dHash is intentionally used only as a *near-duplicate* hint. It is useful
/// when an otherwise identical download was re-encoded or resized, but it is
/// not a crop/partial-image search algorithm and must not be presented as one.
/// The returned value is a fixed-width, lowercase hexadecimal string so it is
/// safe to persist without relying on platform-specific 64-bit integers.
String computeDifferenceHash(Uint8List encodedBytes) {
  final decoded = image.decodeImage(encodedBytes);
  if (decoded == null) {
    throw const FormatException('Unsupported or invalid image bytes');
  }
  return computeDifferenceHashFromImage(decoded);
}

/// Computes a 64-bit dHash from an already-decoded image.
String computeDifferenceHashFromImage(image.Image source) {
  if (source.width <= 0 || source.height <= 0) {
    throw const FormatException('Image dimensions must be positive');
  }

  // Normalize EXIF orientation before sampling. A gallery provider may expose
  // the same pixels with orientation baked into the bitmap or left in EXIF.
  final oriented =
      source.exif.imageIfd.hasOrientation &&
          source.exif.imageIfd.orientation != 1
      ? image.bakeOrientation(source)
      : source;
  final sampled = image.copyResize(
    oriented,
    width: 9,
    height: 8,
    interpolation: image.Interpolation.average,
  );

  final hashBytes = Uint8List(differenceHashBitCount ~/ 8);
  var bitIndex = 0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      final left = _luminance(sampled.getPixel(x, y));
      final right = _luminance(sampled.getPixel(x + 1, y));
      if (left > right) {
        hashBytes[bitIndex >> 3] |= 1 << (7 - (bitIndex & 7));
      }
      bitIndex++;
    }
  }

  return hashBytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// Returns the Hamming distance between two 64-bit hexadecimal dHashes.
///
/// A lower distance means the global layouts are more alike. Thresholds must
/// be calibrated against real user images; callers should also reject an
/// ambiguous best match rather than treating a nearby hash as source proof.
int differenceHashDistance(String first, String second) {
  final normalizedFirst = _normalizeHash(first);
  final normalizedSecond = _normalizeHash(second);
  var distance = 0;
  for (var i = 0; i < differenceHashHexLength; i++) {
    final xor =
        int.parse(normalizedFirst[i], radix: 16) ^
        int.parse(normalizedSecond[i], radix: 16);
    distance += _nibblePopCount[xor];
  }
  return distance;
}

/// Converts Hamming distance to a convenient 0..1 similarity score.
double differenceHashSimilarity(String first, String second) {
  return 1 - differenceHashDistance(first, second) / differenceHashBitCount;
}

bool isValidDifferenceHash(String value) {
  return RegExp(r'^[0-9a-f]{16}$', caseSensitive: false).hasMatch(value.trim());
}

/// A persisted dHash tied to an application-level source identity.
class DifferenceHashReference<T> {
  final String hash;
  final T value;

  const DifferenceHashReference({required this.hash, required this.value});
}

/// A unique, thresholded near-duplicate match.
class DifferenceHashMatch<T> {
  final T value;
  final int distance;

  const DifferenceHashMatch({required this.value, required this.distance});

  double get similarity => 1 - distance / differenceHashBitCount;
}

/// Finds one unambiguous near-duplicate among locally indexed references.
///
/// [maximumDistance] and [minimumDistanceGap] are deliberately required: the
/// project must calibrate them on representative downloads instead of silently
/// inheriting a universal threshold. Multiple pages belonging to the same
/// [DifferenceHashReference.value] are collapsed to their best distance.
DifferenceHashMatch<T>? findUniqueDifferenceHashMatch<T>(
  String queryHash,
  Iterable<DifferenceHashReference<T>> references, {
  required int maximumDistance,
  required int minimumDistanceGap,
}) {
  if (maximumDistance < 0 || maximumDistance > differenceHashBitCount) {
    throw RangeError.range(
      maximumDistance,
      0,
      differenceHashBitCount,
      'maximumDistance',
    );
  }
  if (minimumDistanceGap < 0 || minimumDistanceGap > differenceHashBitCount) {
    throw RangeError.range(
      minimumDistanceGap,
      0,
      differenceHashBitCount,
      'minimumDistanceGap',
    );
  }

  final bestByValue = <T, int>{};
  for (final reference in references) {
    final distance = differenceHashDistance(queryHash, reference.hash);
    final previous = bestByValue[reference.value];
    if (previous == null || distance < previous) {
      bestByValue[reference.value] = distance;
    }
  }
  if (bestByValue.isEmpty) return null;

  final ranked = bestByValue.entries.toList()
    ..sort((first, second) => first.value.compareTo(second.value));
  final best = ranked.first;
  if (best.value > maximumDistance) return null;
  if (ranked.length > 1 && ranked[1].value - best.value < minimumDistanceGap) {
    return null;
  }
  return DifferenceHashMatch<T>(value: best.key, distance: best.value);
}

double _luminance(image.Pixel pixel) {
  // Composite transparency over white. This makes transparent PNG downloads
  // more comparable with JPEG copies that acquired a white background.
  final alpha = pixel.aNormalized;
  final red = pixel.rNormalized * alpha + (1 - alpha);
  final green = pixel.gNormalized * alpha + (1 - alpha);
  final blue = pixel.bNormalized * alpha + (1 - alpha);
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

String _normalizeHash(String value) {
  final normalized = value.trim().toLowerCase();
  if (!isValidDifferenceHash(normalized)) {
    throw const FormatException('A dHash must contain exactly 16 hex digits');
  }
  return normalized;
}

const List<int> _nibblePopCount = <int>[
  0,
  1,
  1,
  2,
  1,
  2,
  2,
  3,
  1,
  2,
  2,
  3,
  2,
  3,
  3,
  4,
];
