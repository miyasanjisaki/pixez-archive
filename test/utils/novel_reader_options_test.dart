import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/novel_reader_options.dart';

void main() {
  test('reader settings stay inside accessible ranges', () {
    expect(clampNovelFontSize(0), minNovelFontSize);
    expect(clampNovelFontSize(50), maxNovelFontSize);
    expect(clampNovelLineHeight(0.5), minNovelLineHeight);
    expect(clampNovelLineHeight(3), maxNovelLineHeight);
  });

  test('reading progress is finite and clamped', () {
    expect(
      calculateNovelReadingProgress(offset: 50, maxScrollExtent: 200),
      0.25,
    );
    expect(calculateNovelReadingProgress(offset: -10, maxScrollExtent: 200), 0);
    expect(calculateNovelReadingProgress(offset: 250, maxScrollExtent: 200), 1);
    expect(calculateNovelReadingProgress(offset: 50, maxScrollExtent: 0), 0);
  });
}
