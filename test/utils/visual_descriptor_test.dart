import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pixez/utils/visual_descriptor.dart';

img.Image _artwork(int seed, {int width = 600, int height = 840}) {
  final random = math.Random(seed);
  final canvas = img.Image(width: width, height: height);
  img.fill(canvas, color: img.ColorRgb8(230, 225, 215));
  for (var i = 0; i < 40; i++) {
    final color = img.ColorRgb8(
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    );
    if (random.nextBool()) {
      final x = random.nextInt(width);
      final y = random.nextInt(height);
      img.fillRect(
        canvas,
        x1: x,
        y1: y,
        x2: math.min(width - 1, x + 40 + random.nextInt(200)),
        y2: math.min(height - 1, y + 40 + random.nextInt(200)),
        color: color,
      );
    } else {
      img.fillCircle(
        canvas,
        x: random.nextInt(width),
        y: random.nextInt(height),
        radius: 20 + random.nextInt(90),
        color: color,
      );
    }
  }
  return canvas;
}

VisualThumb _thumb(img.Image source) => computeVisualThumb(source);

img.Image _jpegRoundTrip(img.Image source, {int quality = 45}) =>
    img.decodeJpg(Uint8List.fromList(img.encodeJpg(source, quality: quality)))!;

void main() {
  final original = _artwork(7);
  final originalThumb = _thumb(original);

  test('thumb encoding round-trips', () {
    final decoded = VisualThumb.decode(originalThumb.encode())!;
    expect(decoded.width, originalThumb.width);
    expect(decoded.height, originalThumb.height);
    expect(decoded.luma, originalThumb.luma);
    expect(VisualThumb.decode(Uint8List.fromList([2, 2, 1])), isNull);
  });

  test('a resized, heavily recompressed copy scores near 1', () {
    final copy = _jpegRoundTrip(img.copyResize(original, width: 333));
    final score = scoreVisualMatch(_thumb(copy), originalThumb)!;
    expect(score.score, greaterThan(0.95));
    expect(score.candidateCoverage, closeTo(1, 0.05));
  });

  test('the top half alone still matches the full artwork', () {
    final top = img.copyCrop(
      original,
      x: 0,
      y: 0,
      width: original.width,
      height: original.height ~/ 2,
    );
    final score = scoreVisualMatch(_thumb(_jpegRoundTrip(top)), originalThumb)!;
    expect(score.score, greaterThan(0.9));
    expect(score.candidateCoverage, lessThan(0.65));
  });

  test('the bottom half alone still matches the full artwork', () {
    final bottom = img.copyCrop(
      original,
      x: 0,
      y: original.height ~/ 2,
      width: original.width,
      height: original.height - original.height ~/ 2,
    );
    final score = scoreVisualMatch(_thumb(bottom), originalThumb)!;
    expect(score.score, greaterThan(0.9));
  });

  test('a screenshot-style frame around the artwork still matches', () {
    final framed = img.Image(width: 720, height: 1100);
    img.fill(framed, color: img.ColorRgb8(255, 255, 255));
    img.fillRect(
      framed,
      x1: 0,
      y1: 0,
      x2: 719,
      y2: 60,
      color: img.ColorRgb8(20, 20, 20),
    );
    img.compositeImage(framed, original, dstX: 60, dstY: 130);
    final score = scoreVisualMatch(_thumb(framed), originalThumb)!;
    expect(score.score, greaterThan(0.88));
    expect(score.queryCoverage, lessThan(0.95));
  });

  test('unrelated artworks stay well below the match threshold', () {
    for (final seed in <int>[1, 2, 3, 4, 5]) {
      final other = _thumb(_artwork(100 + seed));
      final score = scoreVisualMatch(other, originalThumb);
      expect(score?.score ?? 0, lessThan(0.75), reason: 'seed $seed');
    }
  });

  test('a flat image is not comparable', () {
    final flat = img.Image(width: 50, height: 50);
    img.fill(flat, color: img.ColorRgb8(128, 128, 128));
    expect(scoreVisualMatch(_thumb(flat), originalThumb), isNull);
  });
}
