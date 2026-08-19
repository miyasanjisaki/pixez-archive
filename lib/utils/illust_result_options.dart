/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 */

export 'result_sort.dart' show stableSortedCopy;

enum IllustResultSort {
  /// Keep the order returned by the API.
  apiOrder,

  /// Order the currently loaded results by bookmark count.
  bookmarksDesc,

  /// Order the currently loaded results by view count.
  viewsDesc,
}

enum IllustContentFilter { all, illustration, manga }

bool matchesIllustContent(String type, IllustContentFilter filter) {
  return switch (filter) {
    IllustContentFilter.all => true,
    IllustContentFilter.illustration => type == 'illust',
    IllustContentFilter.manga => type == 'manga',
  };
}

Comparator<T>? buildIllustResultComparator<T>(
  IllustResultSort sort, {
  required int Function(T value) bookmarksOf,
  required int Function(T value) viewsOf,
}) {
  return switch (sort) {
    IllustResultSort.apiOrder => null,
    IllustResultSort.bookmarksDesc => (left, right) {
      final byBookmarks = bookmarksOf(right).compareTo(bookmarksOf(left));
      if (byBookmarks != 0) return byBookmarks;
      return viewsOf(right).compareTo(viewsOf(left));
    },
    IllustResultSort.viewsDesc => (left, right) {
      final byViews = viewsOf(right).compareTo(viewsOf(left));
      if (byViews != 0) return byViews;
      return bookmarksOf(right).compareTo(bookmarksOf(left));
    },
  };
}
