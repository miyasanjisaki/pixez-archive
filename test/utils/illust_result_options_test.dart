import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/illust_result_options.dart';

class _Result {
  final String name;
  final String type;
  final int bookmarks;
  final int views;

  const _Result(this.name, this.type, this.bookmarks, this.views);
}

void main() {
  group('matchesIllustContent', () {
    test('uses Pixiv media types instead of tag wording', () {
      expect(matchesIllustContent('illust', IllustContentFilter.illustration),
          isTrue);
      expect(matchesIllustContent('manga', IllustContentFilter.illustration),
          isFalse);
      expect(
          matchesIllustContent('manga', IllustContentFilter.manga), isTrue);
      expect(
          matchesIllustContent('ugoira', IllustContentFilter.manga), isFalse);
    });

    test('all keeps known and future media types', () {
      expect(matchesIllustContent('ugoira', IllustContentFilter.all), isTrue);
      expect(matchesIllustContent('future_type', IllustContentFilter.all),
          isTrue);
    });
  });

  group('loaded result sorting', () {
    final source = <_Result>[
      const _Result('first tie', 'illust', 10, 20),
      const _Result('second tie', 'manga', 10, 20),
      const _Result('most viewed', 'illust', 5, 100),
      const _Result('most bookmarked', 'manga', 50, 10),
    ];

    test('sorts bookmarks descending with views as the secondary key', () {
      final comparator = buildIllustResultComparator<_Result>(
        IllustResultSort.bookmarksDesc,
        bookmarksOf: (value) => value.bookmarks,
        viewsOf: (value) => value.views,
      );

      final sorted = stableSortedCopy(source, comparator);

      expect(sorted.map((item) => item.name), [
        'most bookmarked',
        'first tie',
        'second tie',
        'most viewed',
      ]);
    });

    test('sorts views descending with bookmarks as the secondary key', () {
      final comparator = buildIllustResultComparator<_Result>(
        IllustResultSort.viewsDesc,
        bookmarksOf: (value) => value.bookmarks,
        viewsOf: (value) => value.views,
      );

      final sorted = stableSortedCopy(source, comparator);

      expect(sorted.map((item) => item.name), [
        'most viewed',
        'first tie',
        'second tie',
        'most bookmarked',
      ]);
    });

    test('api order returns a copy without mutating the source', () {
      final comparator = buildIllustResultComparator<_Result>(
        IllustResultSort.apiOrder,
        bookmarksOf: (value) => value.bookmarks,
        viewsOf: (value) => value.views,
      );

      final copied = stableSortedCopy(source, comparator);

      expect(copied, orderedEquals(source));
      expect(identical(copied, source), isFalse);
    });

    test('manga-only results can be sorted without losing complete works', () {
      final manga = source.where(
        (item) => matchesIllustContent(item.type, IllustContentFilter.manga),
      );
      final comparator = buildIllustResultComparator<_Result>(
        IllustResultSort.bookmarksDesc,
        bookmarksOf: (value) => value.bookmarks,
        viewsOf: (value) => value.views,
      );

      final sorted = stableSortedCopy(manga, comparator);

      expect(sorted.map((item) => item.name), [
        'most bookmarked',
        'second tie',
      ]);
      expect(sorted.every((item) => item.type == 'manga'), isTrue);
    });
  });
}
