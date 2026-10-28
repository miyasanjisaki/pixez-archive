/// Pixiv bookmark visibility. Values match the API's `restrict` parameter.
enum BookmarkRestrict { public, private }

/// Work type filter. `null` in a query means "any type".
enum BookmarkWorkType { illust, manga, ugoira }

enum BookmarkAgeFilter { all, allAges, r18 }

enum BookmarkLibrarySort {
  /// Most recently bookmarked first (Pixiv's own order).
  bookmarkedNewest,
  bookmarkedOldest,
  mostBookmarked,
  mostViewed,
  createdNewest,
}

class BookmarkLibraryQuery {
  final String text;
  final BookmarkWorkType? type;
  final BookmarkRestrict? restrict;
  final BookmarkAgeFilter age;
  final BookmarkLibrarySort sort;

  /// Exact Pixiv tag (original spelling) chosen from the tag chips.
  final String? tag;

  /// Artist chosen from the artist picker; [artistName] is display-only.
  final int? artistId;
  final String? artistName;

  const BookmarkLibraryQuery({
    this.text = '',
    this.type,
    this.restrict,
    this.age = BookmarkAgeFilter.all,
    this.sort = BookmarkLibrarySort.bookmarkedNewest,
    this.tag,
    this.artistId,
    this.artistName,
  });

  BookmarkLibraryQuery copyWith({
    String? text,
    BookmarkWorkType? type,
    bool clearType = false,
    BookmarkRestrict? restrict,
    bool clearRestrict = false,
    BookmarkAgeFilter? age,
    BookmarkLibrarySort? sort,
    String? tag,
    bool clearTag = false,
    int? artistId,
    String? artistName,
    bool clearArtist = false,
  }) => BookmarkLibraryQuery(
    text: text ?? this.text,
    type: clearType ? null : (type ?? this.type),
    restrict: clearRestrict ? null : (restrict ?? this.restrict),
    age: age ?? this.age,
    sort: sort ?? this.sort,
    tag: clearTag ? null : (tag ?? this.tag),
    artistId: clearArtist ? null : (artistId ?? this.artistId),
    artistName: clearArtist ? null : (artistName ?? this.artistName),
  );
}

class BookmarkTagFacet {
  final String name;
  final String? translatedName;
  final int count;

  const BookmarkTagFacet({
    required this.name,
    required this.count,
    this.translatedName,
  });
}

class BookmarkArtistFacet {
  final int id;
  final String name;
  final String? avatarUrl;
  final int count;

  const BookmarkArtistFacet({
    required this.id,
    required this.name,
    required this.count,
    this.avatarUrl,
  });
}

/// Tag and artist counts across the local library, most used first.
class BookmarkLibraryFacets {
  final List<BookmarkTagFacet> tags;
  final List<BookmarkArtistFacet> artists;

  const BookmarkLibraryFacets({
    this.tags = const <BookmarkTagFacet>[],
    this.artists = const <BookmarkArtistFacet>[],
  });
}

class BookmarkLibrarySearchResult {
  /// Raw Pixiv illust JSON objects, ready for `Illusts.fromJson`.
  final List<Map<String, dynamic>> illusts;

  /// Total matches; may exceed [illusts] when a display limit was applied.
  final int total;

  const BookmarkLibrarySearchResult({
    required this.illusts,
    required this.total,
  });
}

class BookmarkLibraryStats {
  final int publicCount;
  final int privateCount;
  final bool publicComplete;
  final bool privateComplete;
  final DateTime? lastSync;

  const BookmarkLibraryStats({
    this.publicCount = 0,
    this.privateCount = 0,
    this.publicComplete = false,
    this.privateComplete = false,
    this.lastSync,
  });

  int get total => publicCount + privateCount;

  bool get isComplete => publicComplete && privateComplete;
}

class BookmarkSyncProgress {
  final BookmarkRestrict restrict;
  final int pages;
  final int added;
  final int updated;
  final int removed;

  const BookmarkSyncProgress({
    required this.restrict,
    this.pages = 0,
    this.added = 0,
    this.updated = 0,
    this.removed = 0,
  });
}

class BookmarkSyncResult {
  final int added;
  final int updated;
  final int removed;
  final bool complete;
  final bool cancelled;
  final Object? error;

  const BookmarkSyncResult({
    this.added = 0,
    this.updated = 0,
    this.removed = 0,
    this.complete = false,
    this.cancelled = false,
    this.error,
  });
}

/// One normalised search token. A leading `-` excludes matches.
class BookmarkSearchToken {
  final String value;
  final bool exclude;

  const BookmarkSearchToken(this.value, {this.exclude = false});
}

/// Splits user input into lowercase tokens. Every positive token must match
/// (title, artist, tags or ID); `-token` removes matching works.
List<BookmarkSearchToken> parseBookmarkSearchText(String text) {
  final tokens = <BookmarkSearchToken>[];
  for (final raw in text.trim().split(RegExp(r'[\s　]+'))) {
    if (raw.isEmpty) continue;
    final exclude = raw.length > 1 && raw.startsWith('-');
    final value = normalizeBookmarkSearchText(exclude ? raw.substring(1) : raw);
    if (value.isEmpty) continue;
    tokens.add(BookmarkSearchToken(value, exclude: exclude));
  }
  return tokens;
}

/// Lowercases and folds full-width ASCII (Ａ, ０, ＃) to half-width so that
/// Japanese-IME input still matches.
String normalizeBookmarkSearchText(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString().toLowerCase();
}

/// Builds the lowercase text that a bookmark is searched against.
String buildBookmarkSearchText(Map<String, dynamic> illust) {
  final parts = <String>['${illust['id'] ?? ''}', '${illust['title'] ?? ''}'];
  final user = illust['user'];
  if (user is Map) {
    parts
      ..add('${user['name'] ?? ''}')
      ..add('${user['account'] ?? ''}')
      ..add('${user['id'] ?? ''}');
  }
  final tags = illust['tags'];
  if (tags is List) {
    for (final tag in tags) {
      if (tag is! Map) continue;
      final name = tag['name'];
      final translated = tag['translated_name'];
      if (name is String) parts.add('#$name');
      if (translated is String && translated.isNotEmpty) parts.add(translated);
    }
  }
  final series = illust['series'];
  if (series is Map && series['title'] is String) parts.add(series['title']);
  return normalizeBookmarkSearchText(parts.join('\n'));
}
