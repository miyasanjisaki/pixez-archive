import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/novel_result_options.dart';
import 'package:pixez/utils/result_sort.dart';

class _Result {
  final String name;
  final int bookmarks;
  final int views;

  const _Result(this.name, this.bookmarks, this.views);
}

void main() {
  final source = <_Result>[
    const _Result('first tie', 10, 20),
    const _Result('second tie', 10, 20),
    const _Result('most viewed', 5, 100),
    const _Result('most bookmarked', 50, 10),
  ];

  test('sorts loaded novels by bookmarks without mutating API order', () {
    final sorted = stableSortedCopy(
      source,
      buildNovelResultComparator<_Result>(
        NovelResultSort.bookmarksDesc,
        bookmarksOf: (value) => value.bookmarks,
        viewsOf: (value) => value.views,
      ),
    );

    expect(sorted.map((item) => item.name), [
      'most bookmarked',
      'first tie',
      'second tie',
      'most viewed',
    ]);
    expect(source.map((item) => item.name).first, 'first tie');
  });

  test('sorts loaded novels by views and keeps exact ties stable', () {
    final sorted = stableSortedCopy(
      source,
      buildNovelResultComparator<_Result>(
        NovelResultSort.viewsDesc,
        bookmarksOf: (value) => value.bookmarks,
        viewsOf: (value) => value.views,
      ),
    );

    expect(sorted.map((item) => item.name), [
      'most viewed',
      'first tie',
      'second tie',
      'most bookmarked',
    ]);
  });

  test('API order returns an independent copy', () {
    final copied = stableSortedCopy(
      source,
      buildNovelResultComparator<_Result>(
        NovelResultSort.apiOrder,
        bookmarksOf: (value) => value.bookmarks,
        viewsOf: (value) => value.views,
      ),
    );

    expect(copied, orderedEquals(source));
    expect(identical(copied, source), isFalse);
  });

  test('re-sorts all loaded pages while preserving append order at source', () {
    final loaded = source.take(2).toList();
    loaded.add(const _Result('next page leader', 200, 300));
    final sorted = stableSortedCopy(
      loaded,
      buildNovelResultComparator<_Result>(
        NovelResultSort.bookmarksDesc,
        bookmarksOf: (value) => value.bookmarks,
        viewsOf: (value) => value.views,
      ),
    );

    expect(sorted.first.name, 'next page leader');
    expect(loaded.map((item) => item.name), [
      'first tie',
      'second tie',
      'next page leader',
    ]);
  });
}
