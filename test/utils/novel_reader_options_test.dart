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

  test('normalized progress takes precedence when restoring a position', () {
    expect(
      calculateNovelRestoreOffset(
        savedOffset: 1200,
        savedProgress: 0.4,
        minScrollExtent: 0,
        maxScrollExtent: 5000,
      ),
      2000,
    );
    expect(
      calculateNovelRestoreOffset(
        savedOffset: 1200,
        savedProgress: 1.5,
        minScrollExtent: 100,
        maxScrollExtent: 5100,
      ),
      5100,
    );
  });

  test(
    'legacy positions restore from their pixel offset and stay in range',
    () {
      expect(
        calculateNovelRestoreOffset(
          savedOffset: 1200,
          savedProgress: null,
          minScrollExtent: 0,
          maxScrollExtent: 5000,
        ),
        1200,
      );
      expect(
        calculateNovelRestoreOffset(
          savedOffset: 9000,
          savedProgress: null,
          minScrollExtent: 0,
          maxScrollExtent: 5000,
        ),
        5000,
      );
    },
  );

  test('pending normalized restore cannot overwrite the saved position', () {
    expect(
      shouldAutomaticallyPersistNovelPosition(
        automaticSaveSuppressed: false,
        positionLoadComplete: true,
        restorePending: true,
        hasScrollClients: true,
      ),
      isFalse,
    );
    expect(
      shouldAutomaticallyPersistNovelPosition(
        automaticSaveSuppressed: false,
        positionLoadComplete: true,
        restorePending: false,
        hasScrollClients: true,
      ),
      isTrue,
    );
    expect(
      shouldAutomaticallyPersistNovelPosition(
        automaticSaveSuppressed: false,
        positionLoadComplete: false,
        restorePending: false,
        hasScrollClients: true,
      ),
      isFalse,
    );
    expect(
      shouldAutomaticallyPersistNovelPosition(
        automaticSaveSuppressed: true,
        positionLoadComplete: true,
        restorePending: false,
        hasScrollClients: true,
      ),
      isFalse,
    );
  });
}
