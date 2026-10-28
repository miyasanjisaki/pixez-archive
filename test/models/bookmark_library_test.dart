import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pixez/models/bookmark_library.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> _illust(
  int id, {
  String title = 'work',
  String type = 'illust',
  int xRestrict = 0,
  int bookmarks = 0,
  List<String> tags = const <String>[],
  String artist = 'artist',
  int artistId = 1,
}) => <String, dynamic>{
  'id': id,
  'title': title,
  'type': type,
  'x_restrict': xRestrict,
  'total_bookmarks': bookmarks,
  'total_view': bookmarks * 10,
  'create_date':
      '2024-01-${(id % 28 + 1).toString().padLeft(2, '0')}T00:00:00+09:00',
  'user': <String, dynamic>{
    'id': artistId,
    'name': artist,
    'account': 'acc',
    'profile_image_urls': <String, dynamic>{
      'medium': 'https://i.pximg.net/user-profile/$artistId.jpg',
    },
  },
  'tags': [
    for (final tag in tags)
      <String, dynamic>{'name': tag, 'translated_name': null},
  ],
  'visible': true,
};

/// Serves pages of 2 from an in-memory bookmark list (newest first).
class _FakePixiv {
  final Map<BookmarkRestrict, List<Map<String, dynamic>>> bookmarks = {
    BookmarkRestrict.public: <Map<String, dynamic>>[],
    BookmarkRestrict.private: <Map<String, dynamic>>[],
  };
  int requests = 0;

  Future<Map<String, dynamic>> load(
    int userId,
    BookmarkRestrict restrict,
    String? nextUrl,
  ) async {
    requests++;
    final offset = nextUrl == null
        ? 0
        : int.parse(Uri.parse(nextUrl).queryParameters['offset']!);
    final list = bookmarks[restrict]!;
    final page = list.skip(offset).take(2).toList();
    final next = offset + 2 < list.length
        ? 'https://app-api.pixiv.net/v1/user/bookmarks/illust?offset=${offset + 2}'
        : null;
    return <String, dynamic>{'illusts': page, 'next_url': next};
  }
}

void main() {
  late _FakePixiv pixiv;
  late BookmarkLibrary library;
  const user = 42;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await databaseFactoryFfi.getDatabasesPath();
    await databaseFactoryFfi.deleteDatabase(
      path.join(directory, 'bookmark_library_test.db'),
    );
    pixiv = _FakePixiv();
    library = BookmarkLibrary(
      loadPage: pixiv.load,
      databaseName: 'bookmark_library_test.db',
      pageDelay: Duration.zero,
    );
  });

  test('parses tokens with exclusions and full-width input', () {
    final tokens = parseBookmarkSearchText('  Miku　-Ｒ-18 ');
    expect(tokens.map((token) => token.value), <String>['miku', 'r-18']);
    expect(tokens.map((token) => token.exclude), <bool>[false, true]);
  });

  test('first sync indexes everything and search filters it', () async {
    pixiv.bookmarks[BookmarkRestrict.public]!.addAll([
      _illust(5, title: 'Blue sky', tags: ['風景'], bookmarks: 10),
      _illust(4, title: 'Hatsune', tags: ['初音ミク'], bookmarks: 500),
      _illust(3, title: 'Comic', type: 'manga', tags: ['漫画']),
    ]);
    pixiv.bookmarks[BookmarkRestrict.private]!.add(
      _illust(2, title: 'Secret', xRestrict: 1, artist: 'Hidden'),
    );

    final result = await library.sync(user);
    expect(result.error, isNull);
    expect(result.added, 4);
    final stats = await library.stats(user);
    expect(stats.publicCount, 3);
    expect(stats.privateCount, 1);
    expect(stats.isComplete, isTrue);

    Future<List<int>> ids(BookmarkLibraryQuery query) async =>
        (await library.search(
          user,
          query,
        )).illusts.map((illust) => illust['id'] as int).toList();

    // Pixiv exposes no per-item bookmark time, so only the order inside one
    // visibility is defined.
    expect(
      await ids(const BookmarkLibraryQuery(restrict: BookmarkRestrict.public)),
      <int>[5, 4, 3],
    );
    expect((await library.search(user, const BookmarkLibraryQuery())).total, 4);
    expect(await ids(const BookmarkLibraryQuery(text: 'ミク')), <int>[4]);
    expect(await ids(const BookmarkLibraryQuery(text: 'hidden')), <int>[2]);
    expect(await ids(const BookmarkLibraryQuery(text: '4')), <int>[4]);
    expect(
      await ids(const BookmarkLibraryQuery(type: BookmarkWorkType.manga)),
      <int>[3],
    );
    expect(
      await ids(const BookmarkLibraryQuery(age: BookmarkAgeFilter.r18)),
      <int>[2],
    );
    expect(
      (await ids(
        const BookmarkLibraryQuery(sort: BookmarkLibrarySort.mostBookmarked),
      )).take(2),
      <int>[4, 5],
    );
    expect(await ids(const BookmarkLibraryQuery(text: '-comic -secret')), <int>[
      5,
      4,
    ]);
    expect(await ids(const BookmarkLibraryQuery(text: '100%')), isEmpty);
  });

  test(
    'incremental sync stops at known pages and puts new works first',
    () async {
      final public = pixiv.bookmarks[BookmarkRestrict.public]!;
      public.addAll([for (var id = 10; id >= 1; id--) _illust(id)]);
      await library.sync(user);

      pixiv.requests = 0;
      public.insertAll(0, [_illust(12), _illust(11)]);
      final result = await library.sync(user);
      expect(result.added, 2);
      // One page with the two new works, one fully known page, plus one
      // request for the (empty) private list.
      expect(pixiv.requests, lessThanOrEqualTo(3));
      final first = (await library.search(
        user,
        const BookmarkLibraryQuery(),
      )).illusts.take(3).map((illust) => illust['id']);
      expect(first, <int>[12, 11, 10]);
    },
  );

  test('a full resync removes works that were un-bookmarked', () async {
    final public = pixiv.bookmarks[BookmarkRestrict.public]!;
    public.addAll([_illust(3), _illust(2), _illust(1)]);
    await library.sync(user);
    public.removeAt(1);
    final result = await library.sync(user, full: true);
    expect(result.removed, 1);
    expect((await library.stats(user)).publicCount, 2);
  });

  test('an interrupted first sync resumes from the saved cursor', () async {
    final public = pixiv.bookmarks[BookmarkRestrict.public]!;
    public.addAll([for (var id = 6; id >= 1; id--) _illust(id)]);
    final token = BookmarkSyncCancelToken();
    await library.sync(
      user,
      cancelToken: token,
      onProgress: (progress) {
        if (progress.pages >= 1) token.cancel();
      },
    );
    expect((await library.stats(user)).publicComplete, isFalse);

    final result = await library.sync(user);
    expect(result.error, isNull);
    final stats = await library.stats(user);
    expect(stats.publicCount, 6);
    expect(stats.publicComplete, isTrue);
    final order = (await library.search(
      user,
      const BookmarkLibraryQuery(),
    )).illusts.map((illust) => illust['id']);
    expect(order, <int>[6, 5, 4, 3, 2, 1]);
  });

  test(
    'facets count tags and artists; tag and artist filters are exact',
    () async {
      pixiv.bookmarks[BookmarkRestrict.public]!.addAll([
        _illust(4, tags: ['初音ミク', 'R-18'], artist: 'Alice', artistId: 10),
        _illust(3, tags: ['初音ミク', 'VOCALOID'], artist: 'Alice', artistId: 10),
        _illust(2, tags: ['初音ミク大好き'], artist: 'Bob', artistId: 20),
        _illust(1, tags: ['VOCALOID'], artist: 'Carol', artistId: 30),
      ]);
      await library.sync(user);

      final facets = await library.facets(user);
      expect(facets.tags.map((tag) => tag.name).take(2), <String>[
        'VOCALOID',
        '初音ミク',
      ]);
      expect(facets.tags.any((tag) => tag.name == 'R-18'), isFalse);
      expect(facets.artists.first.id, 10);
      expect(facets.artists.first.count, 2);
      expect(facets.artists.first.avatarUrl, contains('/10.jpg'));

      Future<List<int>> ids(BookmarkLibraryQuery query) async =>
          (await library.search(
            user,
            query,
          )).illusts.map((illust) => illust['id'] as int).toList();

      // Exact tag: "初音ミク大好き" must not match "初音ミク".
      expect(await ids(const BookmarkLibraryQuery(tag: '初音ミク')), <int>[4, 3]);
      expect(await ids(const BookmarkLibraryQuery(artistId: 30)), <int>[1]);
      expect(
        await ids(const BookmarkLibraryQuery(tag: 'vocaloid', artistId: 10)),
        <int>[3],
      );
      final cleared = const BookmarkLibraryQuery(
        tag: 'x',
        artistId: 1,
        artistName: 'n',
      ).copyWith(clearTag: true, clearArtist: true);
      expect(cleared.tag, isNull);
      expect(cleared.artistId, isNull);
      expect(cleared.artistName, isNull);
    },
  );

  test('a v1 database is upgraded and backfilled without resync', () async {
    final directory = await databaseFactoryFfi.getDatabasesPath();
    final dbPath = path.join(directory, 'bookmark_library_test.db');
    final legacy = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
CREATE TABLE bookmark_library_item (
  user_id INTEGER NOT NULL, illust_id INTEGER NOT NULL, restrict TEXT NOT NULL,
  sort_key INTEGER NOT NULL, type TEXT NOT NULL, x_restrict INTEGER NOT NULL,
  total_bookmarks INTEGER NOT NULL, total_view INTEGER NOT NULL,
  create_date TEXT NOT NULL, search_text TEXT NOT NULL, json TEXT NOT NULL,
  PRIMARY KEY (user_id, illust_id))''');
          await db.execute('''
CREATE TABLE bookmark_library_state (
  user_id INTEGER NOT NULL, restrict TEXT NOT NULL,
  complete INTEGER NOT NULL DEFAULT 0, resume_url TEXT, last_sync INTEGER,
  PRIMARY KEY (user_id, restrict))''');
        },
      ),
    );
    await legacy.insert('bookmark_library_item', <String, Object?>{
      'user_id': user,
      'illust_id': 7,
      'restrict': 'public',
      'sort_key': 1,
      'type': 'illust',
      'x_restrict': 0,
      'total_bookmarks': 0,
      'total_view': 0,
      'create_date': '',
      'search_text': '7',
      'json': jsonEncode(
        _illust(7, tags: ['風景'], artist: 'Dana', artistId: 70),
      ),
    });
    await legacy.close();

    final facets = await library.facets(user);
    expect(facets.artists.single.name, 'Dana');
    expect(facets.tags.single.name, '風景');
    final found = await library.search(
      user,
      const BookmarkLibraryQuery(tag: '風景', artistId: 70),
    );
    expect(found.total, 1);
  });
}
