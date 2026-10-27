import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

/// Long side, in pixels, of the grayscale thumbnail kept per image.
///
/// 64 px keeps one descriptor at roughly 3 KB, which is small enough to cache
/// thousands of bookmark previews while still describing composition well
/// enough to match crops that keep at least half of each side.
const int visualThumbLongSide = 64;

const int _coarseGridLongSide = 12;
const int _fineGridLongSide = 24;
const int _minimumGridShortSide = 3;
const int _maxGrid = 32;

/// A compact, aspect-preserving luminance thumbnail.
///
/// Unlike a 64-bit dHash, it keeps enough spatial detail to compare a query
/// against *sub-windows* of a candidate. That is what makes top-half,
/// bottom-half, bordered and lightly cropped copies matchable.
class VisualThumb {
  final int width;
  final int height;
  final Uint8List luma;

  VisualThumb(this.width, this.height, this.luma)
    : assert(width > 0 && height > 0),
      assert(luma.length == width * height);

  /// Serialises as `[width, height, ...luma]`; both sides are at most 255.
  Uint8List encode() {
    final bytes = Uint8List(2 + luma.length);
    bytes[0] = width;
    bytes[1] = height;
    bytes.setRange(2, bytes.length, luma);
    return bytes;
  }

  static VisualThumb? decode(Uint8List? bytes) {
    if (bytes == null || bytes.length < 3) return null;
    final width = bytes[0];
    final height = bytes[1];
    if (width <= 0 || height <= 0 || bytes.length != 2 + width * height) {
      return null;
    }
    return VisualThumb(width, height, Uint8List.sublistView(bytes, 2));
  }
}

/// Builds a [VisualThumb] from an already decoded (and oriented) image.
VisualThumb computeVisualThumb(image.Image source) {
  if (source.width <= 0 || source.height <= 0) {
    throw const FormatException('Image dimensions must be positive');
  }
  final longest = math.max(source.width, source.height);
  final scale = longest <= visualThumbLongSide
      ? 1.0
      : visualThumbLongSide / longest;
  final width = math.max(1, (source.width * scale).round());
  final height = math.max(1, (source.height * scale).round());
  final resized = (width == source.width && height == source.height)
      ? source
      : image.copyResize(
          source,
          width: width,
          height: height,
          interpolation: image.Interpolation.average,
        );
  final luma = Uint8List(width * height);
  var index = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final pixel = resized.getPixel(x, y);
      final value =
          0.299 * pixel.rNormalized +
          0.587 * pixel.gNormalized +
          0.114 * pixel.bNormalized;
      luma[index++] = (value * 255).round().clamp(0, 255);
    }
  }
  return VisualThumb(width, height, luma);
}

/// Where, and how well, a query matched a candidate.
class VisualMatchScore {
  /// Normalised cross-correlation of the best aligned window, in [-1, 1].
  final double score;

  /// Fraction of the *candidate* covered by the matched window (1 = whole
  /// image). Small values mean the query is a partial crop of the candidate.
  final double candidateCoverage;

  /// Fraction of the *query* used for the match. Values below 1 mean the
  /// query had extra borders or UI around the candidate.
  final double queryCoverage;

  const VisualMatchScore({
    required this.score,
    required this.candidateCoverage,
    required this.queryCoverage,
  });
}

/// Scores how likely [query] shows the same artwork as [candidate].
///
/// Two directions are searched:
///  * the query is a crop of the candidate (half image, cut borders), and
///  * the candidate is inside the query (screenshot, added frame or caption).
///
/// A coarse grid scans many windows quickly, then the best window is refined
/// on a finer grid. Returns `null` when either image is too flat to compare.
VisualMatchScore? scoreVisualMatch(VisualThumb query, VisualThumb candidate) {
  final queryIntegral = _Integral(query);
  final candidateIntegral = _Integral(candidate);
  if (queryIntegral.isFlat || candidateIntegral.isFlat) return null;

  final insideCandidate = _searchWindows(
    fixed: queryIntegral,
    sliding: candidateIntegral,
    scales: const <double>[1.0, 0.84, 0.7, 0.58],
  );
  final insideQuery = _searchWindows(
    fixed: candidateIntegral,
    sliding: queryIntegral,
    scales: const <double>[1.0, 0.86, 0.74],
  );

  final best = switch ((insideCandidate, insideQuery)) {
    (null, null) => null,
    (final a?, null) => a,
    (null, final b?) => b,
    (final a?, final b?) => a.score >= b.score ? a : b,
  };
  if (best == null) return null;
  final windowArea = best.window.width * best.window.height;
  final slidingArea = best.sliding.width * best.sliding.height;
  final coverage = (windowArea / slidingArea).clamp(0.0, 1.0);
  final candidateSlides = identical(best.sliding, candidateIntegral);
  return VisualMatchScore(
    score: best.score,
    candidateCoverage: candidateSlides ? coverage : 1.0,
    queryCoverage: candidateSlides ? 1.0 : coverage,
  );
}

class _Window {
  final double x;
  final double y;
  final double width;
  final double height;

  const _Window(this.x, this.y, this.width, this.height);
}

class _WindowMatch {
  final double score;
  final _Window window;
  final _Integral sliding;

  const _WindowMatch(this.score, this.window, this.sliding);
}

_WindowMatch? _searchWindows({
  required _Integral fixed,
  required _Integral sliding,
  required List<double> scales,
}) {
  final aspect = fixed.width / fixed.height;
  // Largest window with the fixed image's aspect ratio inside [sliding].
  var maxWidth = sliding.width.toDouble();
  var maxHeight = maxWidth / aspect;
  if (maxHeight > sliding.height) {
    maxHeight = sliding.height.toDouble();
    maxWidth = maxHeight * aspect;
  }

  final (coarseX, coarseY) = _gridShape(aspect, _coarseGridLongSide);
  final fixedFull = _Window(0, 0, fixed.width.toDouble(), fixed.height * 1.0);
  final fixedCoarse = fixed.vector(fixedFull, coarseX, coarseY);
  if (fixedCoarse == null) return null;

  double bestScore = -2;
  _Window? bestWindow;
  for (final scale in scales) {
    final width = maxWidth * scale;
    final height = maxHeight * scale;
    // A window below ~one coarse cell per pixel no longer carries detail.
    if (width < coarseX || height < coarseY) continue;
    final freeX = sliding.width - width;
    final freeY = sliding.height - height;
    final stepX = math.max(1.0, width * 0.125);
    final stepY = math.max(1.0, height * 0.125);
    for (final y in _positions(freeY, stepY)) {
      for (final x in _positions(freeX, stepX)) {
        final window = _Window(x, y, width, height);
        final vector = sliding.vector(window, coarseX, coarseY);
        if (vector == null) continue;
        final score = _dot(fixedCoarse, vector);
        if (score > bestScore) {
          bestScore = score;
          bestWindow = window;
        }
      }
    }
  }
  if (bestWindow == null) return null;

  // Refine the winner on a finer grid with a small local search.
  final (fineX, fineY) = _gridShape(aspect, _fineGridLongSide);
  final fixedFine = fixed.vector(fixedFull, fineX, fineY);
  if (fixedFine == null) return _WindowMatch(bestScore, bestWindow, sliding);
  var refinedScore = -2.0;
  var refinedWindow = bestWindow;
  final shiftX = math.max(0.5, bestWindow.width * 0.05);
  final shiftY = math.max(0.5, bestWindow.height * 0.05);
  for (final scale in const <double>[0.96, 1.0, 1.04]) {
    final width = bestWindow.width * scale;
    final height = bestWindow.height * scale;
    if (width > sliding.width + 1e-6 || height > sliding.height + 1e-6) {
      continue;
    }
    final centerX = bestWindow.x + bestWindow.width / 2;
    final centerY = bestWindow.y + bestWindow.height / 2;
    for (final dy in const <int>[-1, 0, 1]) {
      for (final dx in const <int>[-1, 0, 1]) {
        final x = (centerX - width / 2 + dx * shiftX).clamp(
          0.0,
          sliding.width - width,
        );
        final y = (centerY - height / 2 + dy * shiftY).clamp(
          0.0,
          sliding.height - height,
        );
        final window = _Window(x, y, width, height);
        final vector = sliding.vector(window, fineX, fineY);
        if (vector == null) continue;
        final score = _dot(fixedFine, vector);
        if (score > refinedScore) {
          refinedScore = score;
          refinedWindow = window;
        }
      }
    }
  }
  if (refinedScore < -1) return _WindowMatch(bestScore, bestWindow, sliding);
  return _WindowMatch(refinedScore, refinedWindow, sliding);
}

Iterable<double> _positions(double free, double step) sync* {
  if (free <= 1e-6) {
    yield 0;
    return;
  }
  for (var value = 0.0; value < free; value += step) {
    yield value;
  }
  yield free;
}

(int, int) _gridShape(double aspect, int longSide) {
  if (aspect >= 1) {
    return (
      longSide,
      math.max(_minimumGridShortSide, (longSide / aspect).round()),
    );
  }
  return (
    math.max(_minimumGridShortSide, (longSide * aspect).round()),
    longSide,
  );
}

double _dot(Float64List a, Float64List b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

/// Summed-area table with bilinear sampling, so arbitrary fractional boxes
/// can be averaged in constant time.
class _Integral {
  final int width;
  final int height;
  final Float64List _table;
  late final bool isFlat = _computeFlat();

  _Integral(VisualThumb thumb)
    : width = thumb.width,
      height = thumb.height,
      _table = Float64List((thumb.width + 1) * (thumb.height + 1)) {
    final stride = width + 1;
    for (var y = 0; y < height; y++) {
      var rowSum = 0.0;
      for (var x = 0; x < width; x++) {
        rowSum += thumb.luma[y * width + x];
        _table[(y + 1) * stride + x + 1] = _table[y * stride + x + 1] + rowSum;
      }
    }
  }

  bool _computeFlat() {
    final full = vector(
      _Window(0, 0, width.toDouble(), height.toDouble()),
      math.min(8, width),
      math.min(8, height),
      returnRaw: true,
    );
    return full == null;
  }

  // Scratch buffers reused across calls (one integral is only ever used by a
  // single synchronous scoring pass).
  final Int32List _x0 = Int32List(_maxGrid + 1);
  final Int32List _x1 = Int32List(_maxGrid + 1);
  final Float64List _fx = Float64List(_maxGrid + 1);
  Float64List _points = Float64List(0);

  /// Averages [window] into a `cellsX × cellsY` grid, then returns the
  /// zero-mean, unit-length vector (or `null` for a featureless window).
  Float64List? vector(
    _Window window,
    int cellsX,
    int cellsY, {
    bool returnRaw = false,
  }) {
    final values = Float64List(cellsX * cellsY);
    final cellWidth = window.width / cellsX;
    final cellHeight = window.height / cellsY;
    final cellArea = cellWidth * cellHeight;
    if (cellArea <= 0 || cellsX > _maxGrid || cellsY > _maxGrid) return null;

    // Sample the integral once per grid corner (bilinear), then every cell
    // sum is a difference of four corners.
    final stride = width + 1;
    for (var cx = 0; cx <= cellsX; cx++) {
      var x = window.x + cx * cellWidth;
      if (x < 0) x = 0;
      if (x > width) x = width.toDouble();
      final x0 = x.floor();
      _x0[cx] = x0;
      _x1[cx] = x0 < width ? x0 + 1 : width;
      _fx[cx] = x - x0;
    }
    final pointStride = cellsX + 1;
    if (_points.length < pointStride * (cellsY + 1)) {
      _points = Float64List(pointStride * (cellsY + 1));
    }
    final points = _points;
    for (var cy = 0; cy <= cellsY; cy++) {
      var y = window.y + cy * cellHeight;
      if (y < 0) y = 0;
      if (y > height) y = height.toDouble();
      final y0 = y.floor();
      final y1 = y0 < height ? y0 + 1 : height;
      final fy = y - y0;
      final row0 = y0 * stride;
      final row1 = y1 * stride;
      for (var cx = 0; cx <= cellsX; cx++) {
        final fx = _fx[cx];
        final a = _x0[cx];
        final b = _x1[cx];
        final top =
            _table[row0 + a] + (_table[row0 + b] - _table[row0 + a]) * fx;
        final bottom =
            _table[row1 + a] + (_table[row1 + b] - _table[row1 + a]) * fx;
        points[cy * pointStride + cx] = top + (bottom - top) * fy;
      }
    }

    var mean = 0.0;
    var index = 0;
    for (var cy = 0; cy < cellsY; cy++) {
      final topRow = cy * pointStride;
      final bottomRow = topRow + pointStride;
      for (var cx = 0; cx < cellsX; cx++) {
        final sum =
            points[bottomRow + cx + 1] -
            points[bottomRow + cx] -
            points[topRow + cx + 1] +
            points[topRow + cx];
        final value = sum / cellArea;
        values[index++] = value;
        mean += value;
      }
    }
    mean /= values.length;
    var norm = 0.0;
    for (var i = 0; i < values.length; i++) {
      final centered = values[i] - mean;
      values[i] = centered;
      norm += centered * centered;
    }
    // Standard deviation below ~2 grey levels: nothing to correlate.
    if (norm / values.length < 4) return null;
    if (returnRaw) return values;
    norm = math.sqrt(norm);
    for (var i = 0; i < values.length; i++) {
      values[i] /= norm;
    }
    return values;
  }
}
