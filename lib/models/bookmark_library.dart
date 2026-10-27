import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart';
import 'package:pixez/models/bookmark_library_query.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

export 'package:pixez/models/bookmark_library_query.dart';

const String _items = 'bookmark_library_item';
const String _state = 'bookmark_library_state';

/// Loads one page of the current user's bookmarks.
///
/// [nextUrl] is `null` for the first page; afterwards it is the `next_url`
/// returned by Pixiv. Implementations return the decoded JSON body.
typedef BookmarkPageLoader =
    Future<Map<String, dynamic>> Function(
      int userId,
      BookmarkRestrict restrict,
      String? nextUrl,
    );

/// Cooperative cancellation for a running sync.
class BookmarkSyncCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// Local, searchable copy of the signed-in user's illustration and manga
/// bookmarks.
///
/// Pixiv's app API can only list bookmarks (optionally by bookmark tag); it
/// cannot search them by title, artist or tag. This library mirrors the list
/// into SQLite once, then keeps it fresh with cheap incremental syncs that
/// stop as soon as an already-known page is reached. Only metadata is stored;
/// images are still loaded on demand.
class BookmarkLibrary {
  final String databaseName;
  final BookmarkPageLoader loadPage;
  final Duration pageDelay;
  Future<Database>? _opening;

  BookmarkLibrary({
    required this.loadPage,
    this.databaseName = 'bookmark_library.db',
    this.pageDelay = const Duration(milliseconds: 300),
  });

  Future<Database> _database() => _opening ??= _open();

  Future<Database> _open() async {
    final databasesPath = await getDatabasesPath();
    return openDatabase(
      join(databasesPath, databaseName),
      version: 1,
      onCreate: (database, version) async {
        await database.execute('''
CREATE TABLE $_items (
  user_id INTEGER NOT NULL,
  illust_id INTEGER NOT NULL,
  restrict TEXT NOT NULL,
  sort_key INTEGER NOT NULL,
  type TEXT NOT NULL,
  x_restrict INTEGER NOT NULL,
  total_bookmarks INTEGER NOT NULL,
  total_view INTEGER NOT NULL,
  create_date TEXT NOT NULL,
  search_text TEXT NOT NULL,
  json TEXT NOT NULL,
  PRIMARY KEY (user_id, illust_id)
)''');
        await database.execute(
          'CREATE INDEX ${_items}_order ON $_items (user_id, sort_key DESC)',
        );
        await database.execute('''
CREATE TABLE $_state (
  user_id INTEGER NOT NULL,
  restrict TEXT NOT NULL,
  complete INTEGER NOT NULL DEFAULT 0,
  resume_url TEXT,
  last_sync INTEGER,
  PRIMARY KEY (user_id, restrict)
)''');
      },
    );
  }

  Future<BookmarkLibraryStats> stats(int userId) async {
    final database = await _database();
    final counts = await database.rawQuery(
      'SELECT restrict, COUNT(*) AS n FROM $_items WHERE user_id = ? '
      'GROUP BY restrict',
      <Object>[userId],
    );
    final states = await database.query(
      _state,
      where: 'user_id = ?',
      whereArgs: <Object>[userId],
    );
    int count(BookmarkRestrict restrict) =>
        (counts.firstWhere(
              (row) => row['restrict'] == restrict.name,
              orElse: () => const <String, Object?>{'n': 0},
            )['n']
            as int?) ??
        0;
    bool complete(BookmarkRestrict restrict) => states.any(
      (row) => row['restrict'] == restrict.name && row['complete'] == 1,
    );
    int? lastSync;
    for (final row in states) {
      final value = row['last_sync'];
      if (value is int && (lastSync == null || value > lastSync)) {
        lastSync = value;
      }
    }
    return BookmarkLibraryStats(
      publicCount: count(BookmarkRestrict.public),
      privateCount: count(BookmarkRestrict.private),
      publicComplete: complete(BookmarkRestrict.public),
      privateComplete: complete(BookmarkRestrict.private),
      lastSync: lastSync == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastSync),
    );
  }

  Future<BookmarkLibrarySearchResult> search(
    int userId,
    BookmarkLibraryQuery query, {
    int limit = 3000,
  }) async {
    final database = await _database();
    final where = <String>['user_id = ?'];
    final args = <Object>[userId];
    if (query.restrict != null) {
      where.add('restrict = ?');
      args.add(query.restrict!.name);
    }
    if (query.type != null) {
      where.add('type = ?');
      args.add(query.type!.name);
    }
    switch (query.age) {
      case BookmarkAgeFilter.allAges:
        where.add('x_restrict = 0');
      case BookmarkAgeFilter.r18:
        where.add('x_restrict > 0');
      case BookmarkAgeFilter.all:
        break;
    }
    for (final token in parseBookmarkSearchText(query.text)) {
      where.add(
        token.exclude
            ? "search_text NOT LIKE ? ESCAPE '\\'"
            : "search_text LIKE ? ESCAPE '\\'",
      );
      args.add('%${_escapeLike(token.value)}%');
    }
    final whereSql = where.join(' AND ');
    final orderBy = switch (query.sort) {
      BookmarkLibrarySort.bookmarkedNewest => 'sort_key DESC',
      BookmarkLibrarySort.bookmarkedOldest => 'sort_key ASC',
      BookmarkLibrarySort.mostBookmarked =>
        'total_bookmarks DESC, sort_key DESC',
      BookmarkLibrarySort.mostViewed => 'total_view DESC, sort_key DESC',
      BookmarkLibrarySort.createdNewest => 'create_date DESC, illust_id DESC',
    };
    final totalRows = await database.rawQuery(
      'SELECT COUNT(*) AS n FROM $_items WHERE $whereSql',
      args,
    );
    final rows = await database.rawQuery(
      'SELECT json FROM $_items WHERE $whereSql ORDER BY $orderBy LIMIT ?',
      <Object>[...args, limit],
    );
    return BookmarkLibrarySearchResult(
      total: (totalRows.first['n'] as int?) ?? 0,
      illusts: rows
          .map(
            (row) => Map<String, dynamic>.from(
              jsonDecode(row['json']! as String) as Map,
            ),
          )
          .toList(growable: false),
    );
  }

  /// Rows in bookmark order, for feeding the visual bookmark scanner without
  /// paging the Pixiv API again.
  Future<List<Map<String, dynamic>>> page(
    int userId,
    BookmarkRestrict restrict, {
    required int offset,
    int limit = 60,
  }) async {
    final database = await _database();
    final rows = await database.query(
      _items,
      columns: const <String>['json'],
      where: 'user_id = ? AND restrict = ?',
      whereArgs: <Object>[userId, restrict.name],
      orderBy: 'sort_key DESC',
      limit: limit,
      offset: offset,
    );
    return rows
        .map(
          (row) => Map<String, dynamic>.from(
            jsonDecode(row['json']! as String) as Map,
          ),
        )
        .toList(growable: false);
  }

  /// Removes one work, e.g. right after the user un-bookmarks it in the app.
  Future<void> remove(int userId, int illustId) async {
    final database = await _database();
    await database.delete(
      _items,
      where: 'user_id = ? AND illust_id = ?',
      whereArgs: <Object>[userId, illustId],
    );
  }

  Future<void> clear(int userId) async {
    final database = await _database();
    await database.transaction((transaction) async {
      await transaction.delete(
        _items,
        where: 'user_id = ?',
        whereArgs: <Object>[userId],
      );
      await transaction.delete(
        _state,
        where: 'user_id = ?',
        whereArgs: <Object>[userId],
      );
    });
  }

  /// Brings the local copy up to date with Pixiv.
  ///
  /// The default incremental sync reads from the newest bookmark and stops
  /// at the first page whose works are all known, so it normally costs one or
  /// two requests. The first sync (or [full]) walks every page; an
  /// interrupted walk resumes from the saved cursor next time. Only a
  /// completed full walk deletes works that are no longer bookmarked.
  Future<BookmarkSyncResult> sync(
    int userId, {
    bool full = false,
    BookmarkSyncCancelToken? cancelToken,
    void Function(BookmarkSyncProgress progress)? onProgress,
  }) async {
    final token = cancelToken ?? BookmarkSyncCancelToken();
    var added = 0;
    var updated = 0;
    var removed = 0;
    var complete = true;
    for (final restrict in BookmarkRestrict.values) {
      final result = await _syncRestrict(
        userId,
        restrict,
        full: full,
        token: token,
        onProgress: onProgress,
      );
      added += result.added;
      updated += result.updated;
      removed += result.removed;
      complete = complete && result.complete;
      if (result.cancelled || result.error != null) {
        return BookmarkSyncResult(
          added: added,
          updated: updated,
          removed: removed,
          cancelled: result.cancelled,
          error: result.error,
        );
      }
    }
    return BookmarkSyncResult(
      added: added,
      updated: updated,
      removed: removed,
      complete: complete,
    );
  }

  Future<BookmarkSyncResult> _syncRestrict(
    int userId,
    BookmarkRestrict restrict, {
    required bool full,
    required BookmarkSyncCancelToken token,
    void Function(BookmarkSyncProgress progress)? onProgress,
  }) async {
    final database = await _database();
    final stateRows = await database.query(
      _state,
      where: 'user_id = ? AND restrict = ?',
      whereArgs: <Object>[userId, restrict.name],
    );
    final wasComplete =
        stateRows.isNotEmpty && stateRows.first['complete'] == 1;
    final resumeUrl = stateRows.isEmpty
        ? null
        : stateRows.first['resume_url'] as String?;
    // Walk everything when asked to, or when no earlier walk left a cursor.
    final fullWalk = full || (!wasComplete && resumeUrl == null);

    var added = 0;
    var updated = 0;
    var removed = 0;
    var pages = 0;
    void report() => onProgress?.call(
      BookmarkSyncProgress(
        restrict: restrict,
        pages: pages,
        added: added,
        updated: updated,
        removed: removed,
      ),
    );

    // Keys are spaced by wall-clock time, so works first seen in a later sync
    // always sort above everything stored earlier.
    final runBase = DateTime.now().millisecondsSinceEpoch * 1000;
    var index = 0;
    final seen = <int>{};
    String? cursor;
    var reachedEnd = false;
    report();
    try {
      while (true) {
        if (token.isCancelled) {
          if (fullWalk) await _saveState(database, userId, restrict, cursor);
          return BookmarkSyncResult(
            added: added,
            updated: updated,
            cancelled: true,
          );
        }
        final json = await loadPage(userId, restrict, cursor);
        final illusts = _illustMaps(json);
        final known = await _knownIds(
          database,
          userId,
          illusts.map((illust) => illust['id']).whereType<int>(),
        );
        final batch = database.batch();
        for (final illust in illusts) {
          final id = illust['id'];
          if (id is! int || !seen.add(id)) continue;
          index++;
          if (known.contains(id)) {
            batch.update(
              _items,
              _row(userId, restrict, illust, fullWalk ? runBase - index : null),
              where: 'user_id = ? AND illust_id = ?',
              whereArgs: <Object>[userId, id],
            );
            updated++;
          } else {
            batch.insert(
              _items,
              _row(userId, restrict, illust, runBase - index),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            added++;
          }
        }
        await batch.commit(noResult: true);
        pages++;
        final next = json['next_url'];
        cursor = next is String && next.isNotEmpty ? next : null;
        if (fullWalk) await _saveState(database, userId, restrict, cursor);
        report();
        if (cursor == null) {
          reachedEnd = true;
          break;
        }
        if (!fullWalk && illusts.isNotEmpty && known.length >= illusts.length) {
          break;
        }
        await Future<void>.delayed(pageDelay);
      }

      if (fullWalk && reachedEnd) {
        removed = await _deleteUnseen(database, userId, restrict, seen);
        await _saveState(database, userId, restrict, null, complete: true);
      } else if (!fullWalk && !wasComplete && resumeUrl != null) {
        final deep = await _resumeDeepWalk(
          database,
          userId,
          restrict,
          resumeUrl,
          token,
          onPage: (newRows) {
            pages++;
            added += newRows;
            report();
          },
        );
        if (deep != null) return deep.withCounts(added, updated);
      } else {
        await _touch(database, userId, restrict);
      }
      report();
      return BookmarkSyncResult(
        added: added,
        updated: updated,
        removed: removed,
        complete: fullWalk ? reachedEnd : true,
      );
    } catch (error) {
      return BookmarkSyncResult(added: added, updated: updated, error: error);
    }
  }

  /// Continues an interrupted first sync below everything already stored.
  /// Returns a non-null result only when the walk stopped early.
  Future<BookmarkSyncResult?> _resumeDeepWalk(
    Database database,
    int userId,
    BookmarkRestrict restrict,
    String startUrl,
    BookmarkSyncCancelToken token, {
    required void Function(int newRows) onPage,
  }) async {
    final minRows = await database.rawQuery(
      'SELECT MIN(sort_key) AS k FROM $_items WHERE user_id = ? AND restrict = ?',
      <Object>[userId, restrict.name],
    );
    var key = (minRows.first['k'] as int?) ?? 0;
    String? cursor = startUrl;
    while (cursor != null) {
      if (token.isCancelled) {
        await _saveState(database, userId, restrict, cursor);
        return const BookmarkSyncResult(cancelled: true);
      }
      final json = await loadPage(userId, restrict, cursor);
      final illusts = _illustMaps(json);
      final batch = database.batch();
      var newRows = 0;
      for (final illust in illusts) {
        if (illust['id'] is! int) continue;
        key--;
        batch.insert(
          _items,
          _row(userId, restrict, illust, key),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        newRows++;
      }
      await batch.commit(noResult: true);
      final next = json['next_url'];
      cursor = next is String && next.isNotEmpty ? next : null;
      await _saveState(database, userId, restrict, cursor);
      onPage(newRows);
      if (cursor != null) await Future<void>.delayed(pageDelay);
    }
    await _saveState(database, userId, restrict, null, complete: true);
    return null;
  }

  Future<Set<int>> _knownIds(
    Database database,
    int userId,
    Iterable<int> ids,
  ) async {
    final list = ids.toList(growable: false);
    if (list.isEmpty) return <int>{};
    final placeholders = List.filled(list.length, '?').join(',');
    final rows = await database.rawQuery(
      'SELECT illust_id FROM $_items WHERE user_id = ? '
      'AND illust_id IN ($placeholders)',
      <Object>[userId, ...list],
    );
    return rows.map((row) => row['illust_id']! as int).toSet();
  }

  Future<int> _deleteUnseen(
    Database database,
    int userId,
    BookmarkRestrict restrict,
    Set<int> seen,
  ) async {
    final rows = await database.query(
      _items,
      columns: const <String>['illust_id'],
      where: 'user_id = ? AND restrict = ?',
      whereArgs: <Object>[userId, restrict.name],
    );
    final stale = rows
        .map((row) => row['illust_id']! as int)
        .where((id) => !seen.contains(id))
        .toList(growable: false);
    final batch = database.batch();
    for (final id in stale) {
      batch.delete(
        _items,
        where: 'user_id = ? AND illust_id = ?',
        whereArgs: <Object>[userId, id],
      );
    }
    await batch.commit(noResult: true);
    return stale.length;
  }

  Future<void> _saveState(
    Database database,
    int userId,
    BookmarkRestrict restrict,
    String? resumeUrl, {
    bool complete = false,
  }) async {
    await database.insert(_state, <String, Object?>{
      'user_id': userId,
      'restrict': restrict.name,
      'complete': complete ? 1 : 0,
      'resume_url': resumeUrl,
      'last_sync': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _touch(
    Database database,
    int userId,
    BookmarkRestrict restrict,
  ) async {
    await database.update(
      _state,
      <String, Object?>{'last_sync': DateTime.now().millisecondsSinceEpoch},
      where: 'user_id = ? AND restrict = ?',
      whereArgs: <Object>[userId, restrict.name],
    );
  }

  Map<String, Object?> _row(
    int userId,
    BookmarkRestrict restrict,
    Map<String, dynamic> illust,
    int? sortKey,
  ) {
    int number(Object? value) =>
        value is int ? value : int.tryParse('${value ?? ''}') ?? 0;
    return <String, Object?>{
      'user_id': userId,
      'illust_id': illust['id'],
      'restrict': restrict.name,
      'sort_key': ?sortKey,
      'type': '${illust['type'] ?? 'illust'}',
      'x_restrict': number(illust['x_restrict']),
      'total_bookmarks': number(illust['total_bookmarks']),
      'total_view': number(illust['total_view']),
      'create_date': '${illust['create_date'] ?? ''}',
      'search_text': buildBookmarkSearchText(illust),
      'json': jsonEncode(illust),
    };
  }
}

List<Map<String, dynamic>> _illustMaps(Map<String, dynamic> json) {
  final raw = json['illusts'];
  if (raw is! List) {
    throw const FormatException('Pixiv bookmark response omitted illusts');
  }
  return raw
      .whereType<Map>()
      .map((value) => Map<String, dynamic>.from(value))
      .where((illust) => illust['id'] is int && illust['visible'] != false)
      .toList(growable: false);
}

extension on BookmarkSyncResult {
  BookmarkSyncResult withCounts(int added, int updated) => BookmarkSyncResult(
    added: added,
    updated: updated,
    removed: removed,
    complete: complete,
    cancelled: cancelled,
    error: error,
  );
}

String _escapeLike(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll('%', '\\%')
    .replaceAll('_', '\\_');
