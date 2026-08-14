import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pixez/utils/image_perceptual_hash.dart';

void main() {
  image.Image horizontalGradient({int width = 180, int height = 120}) {
    final result = image.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final value = (255 * x / (width - 1)).round();
        result.setPixelRgba(x, y, value, value, value, 255);
      }
    }
    return result;
  }

  image.Image texturedPattern({int width = 240, int height = 160}) {
    final result = image.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final checker = ((x ~/ 30) + (y ~/ 24)) % 2;
        final diagonal = (x * 3 + y * 5) % 96;
        final value = (checker == 0 ? 45 : 145) + diagonal;
        result.setPixelRgba(
          x,
          y,
          value.clamp(0, 255),
          (255 - value).clamp(0, 255),
          ((value * 2) % 256).clamp(0, 255),
          255,
        );
      }
    }
    return result;
  }

  test('dHash is fixed-width and deterministic', () {
    final source = horizontalGradient();

    final first = computeDifferenceHashFromImage(source);
    final second = computeDifferenceHashFromImage(source.clone());

    expect(first, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(second, first);
    expect(differenceHashDistance(first, second), 0);
    expect(differenceHashSimilarity(first, second), 1);
  });

  test('survives ordinary resize and JPEG re-encoding', () {
    final source = texturedPattern();
    final resized = image.copyResize(source, width: 120, height: 80);
    final jpeg = Uint8List.fromList(image.encodeJpg(resized, quality: 82));

    final originalHash = computeDifferenceHashFromImage(source);
    final reencodedHash = computeDifferenceHash(jpeg);

    expect(originalHash, isNot('0000000000000000'));
    expect(originalHash, isNot('ffffffffffffffff'));
    expect(
      differenceHashDistance(originalHash, reencodedHash),
      lessThanOrEqualTo(2),
    );
  });

  test('distinguishes an opposite global gradient', () {
    final leftToRight = horizontalGradient();
    final rightToLeft = image.flipHorizontal(leftToRight.clone());

    final distance = differenceHashDistance(
      computeDifferenceHashFromImage(leftToRight),
      computeDifferenceHashFromImage(rightToLeft),
    );

    expect(distance, greaterThanOrEqualTo(56));
  });

  test('rejects malformed persisted hashes', () {
    expect(
      () => differenceHashDistance('1234', List.filled(16, '0').join()),
      throwsFormatException,
    );
  });

  test('returns only a thresholded and separated local match', () {
    const query = '0000000000000000';
    const exact = DifferenceHashReference(hash: query, value: 101);
    const nearbySameWork = DifferenceHashReference(
      hash: '0000000000000001',
      value: 101,
    );
    const distant = DifferenceHashReference(
      hash: '00000000000000ff',
      value: 202,
    );

    final match = findUniqueDifferenceHashMatch(
      query,
      const [exact, nearbySameWork, distant],
      maximumDistance: 6,
      minimumDistanceGap: 3,
    );

    expect(match?.value, 101);
    expect(match?.distance, 0);
  });

  test('rejects an ambiguous nearest neighbour', () {
    final match = findUniqueDifferenceHashMatch(
      '0000000000000000',
      const [
        DifferenceHashReference(hash: '0000000000000001', value: 101),
        DifferenceHashReference(hash: '0000000000000002', value: 202),
      ],
      maximumDistance: 6,
      minimumDistanceGap: 2,
    );

    expect(match, isNull);
  });
}
