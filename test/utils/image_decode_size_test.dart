import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/image_decode_size.dart';

void main() {
  group('calculateImageCacheDimension', () {
    test('converts logical pixels to physical decode pixels', () {
      expect(calculateImageCacheDimension(120, 3), 360);
      expect(calculateImageCacheDimension(100.1, 2), 201);
    });

    test('caps unusually large thumbnail decodes', () {
      expect(calculateImageCacheDimension(2000, 3), 4096);
      expect(
        calculateImageCacheDimension(2000, 3, maximumDimension: 2048),
        2048,
      );
    });

    test('ignores invalid or unbounded dimensions', () {
      expect(calculateImageCacheDimension(null, 3), isNull);
      expect(calculateImageCacheDimension(double.infinity, 3), isNull);
      expect(calculateImageCacheDimension(100, 0), isNull);
    });
  });
}
