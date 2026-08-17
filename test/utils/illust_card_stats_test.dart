import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/illust_card_stats.dart';

void main() {
  group('formatIllustCardStatCount', () {
    test('keeps small counts unchanged', () {
      expect(formatIllustCardStatCount(0), '0');
      expect(formatIllustCardStatCount(999), '999');
    });

    test(
      'uses the same compact K and M presentation as illustration cards',
      () {
        expect(formatIllustCardStatCount(1000), '1.0K');
        expect(formatIllustCardStatCount(9999), '10.0K');
        expect(formatIllustCardStatCount(10000), '10K');
        expect(formatIllustCardStatCount(1000000), '1.0M');
        expect(formatIllustCardStatCount(10000000), '10M');
      },
    );
  });

  group('hasCompleteIllustCardStats', () {
    test('requires both counters to already be present', () {
      expect(hasCompleteIllustCardStats(bookmarks: 0, views: 0), isTrue);
      expect(hasCompleteIllustCardStats(bookmarks: null, views: 1), isFalse);
      expect(hasCompleteIllustCardStats(bookmarks: 1, views: null), isFalse);
    });
  });
}
