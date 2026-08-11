/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 */

enum NovelResultSort {
  /// Keep the order returned by the Pixiv API.
  apiOrder,

  /// Order only the currently loaded novels by bookmark count.
  bookmarksDesc,

  /// Order only the currently loaded novels by view count.
  viewsDesc,
}

Comparator<T>? buildNovelResultComparator<T>(
  NovelResultSort sort, {
  required int Function(T value) bookmarksOf,
  required int Function(T value) viewsOf,
}) {
  return switch (sort) {
    NovelResultSort.apiOrder => null,
    NovelResultSort.bookmarksDesc => (left, right) {
      final byBookmarks = bookmarksOf(right).compareTo(bookmarksOf(left));
      if (byBookmarks != 0) return byBookmarks;
      return viewsOf(right).compareTo(viewsOf(left));
    },
    NovelResultSort.viewsDesc => (left, right) {
      final byViews = viewsOf(right).compareTo(viewsOf(left));
      if (byViews != 0) return byViews;
      return bookmarksOf(right).compareTo(bookmarksOf(left));
    },
  };
}
