/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 */

/// Returns a stably sorted copy without mutating the API-backed source list.
List<T> stableSortedCopy<T>(Iterable<T> source, Comparator<T>? comparator) {
  final indexed = source.indexed.toList();
  if (comparator != null) {
    indexed.sort((left, right) {
      final compared = comparator(left.$2, right.$2);
      return compared != 0 ? compared : left.$1.compareTo(right.$1);
    });
  }
  return [for (final item in indexed) item.$2];
}
