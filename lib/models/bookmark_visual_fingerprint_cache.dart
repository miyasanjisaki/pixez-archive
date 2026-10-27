import 'dart:typed_data';

import 'package:path/path.dart';
import 'package:pixez/utils/bookmark_visual_search.dart';
import 'package:pixez/utils/image_perceptual_hash.dart';
import 'package:pixez/utils/visual_descriptor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _table = 'bookmark_visual_fingerprint';

/// SQLite-backed [BookmarkVisualFingerprintCache].
///
/// Keys are Pixiv preview URLs. Those URLs embed the upload timestamp, so an
/// edited artwork gets a new key instead of a stale fingerprint. Only derived
/// fingerprints are stored (about 3 KB each), never image bytes.
class SqliteBookmarkVisualFingerprintCache
    implements BookmarkVisualFingerprintCache {
  static const int defaultMaximumEntries = 20000;

  final String databaseName;
  final int maximumEntries;
  Future<Database>? _opening;
  int _writesSinceTrim = 0;

  SqliteBookmarkVisualFingerprintCache({
    this.databaseName = 'bookmark_visual_fingerprint.db',
    this.maximumEntries = defaultMaximumEntries,
  }) : assert(maximumEntries > 0);

  Future<Database> _database() => _opening ??= _open();

  Future<Database> _open() async {
    final databasesPath = await getDatabasesPath();
    return openDatabase(
      join(databasesPath, databaseName),
      version: 1,
      onCreate: (database, version) async {
        await database.execute('''
CREATE TABLE $_table (
  url TEXT PRIMARY KEY,
  sha256 TEXT NOT NULL,
  dhash TEXT,
  top_dhash TEXT,
  bottom_dhash TEXT,
  thumb BLOB,
  updated_at INTEGER NOT NULL
)
''');
        await database.execute(
          'CREATE INDEX ${_table}_updated_at ON $_table (updated_at)',
        );
      },
    );
  }

  @override
  Future<BookmarkVisualFingerprint?> lookup(String imageUrl) async {
    final database = await _database();
    final rows = await database.query(
      _table,
      where: 'url = ?',
      whereArgs: <Object>[imageUrl],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    String? hash(String column) {
      final value = row[column];
      return value is String && isValidDifferenceHash(value) ? value : null;
    }

    final regions = <BookmarkVisualRegion, String>{
      if (hash('dhash') case final full?) BookmarkVisualRegion.full: full,
      if (hash('top_dhash') case final top?) BookmarkVisualRegion.top: top,
      if (hash('bottom_dhash') case final bottom?)
        BookmarkVisualRegion.bottom: bottom,
    };
    final thumb = row['thumb'];
    return BookmarkVisualFingerprint(
      sha256: row['sha256']! as String,
      differenceHash: hash('dhash'),
      regionDifferenceHashes: regions,
      thumb: VisualThumb.decode(thumb is Uint8List ? thumb : null),
    );
  }

  @override
  Future<void> store(
    String imageUrl,
    BookmarkVisualFingerprint fingerprint,
  ) async {
    final database = await _database();
    await database.insert(_table, <String, Object?>{
      'url': imageUrl,
      'sha256': fingerprint.sha256,
      'dhash': fingerprint.differenceHash,
      'top_dhash': fingerprint.regionDifferenceHashes[BookmarkVisualRegion.top],
      'bottom_dhash':
          fingerprint.regionDifferenceHashes[BookmarkVisualRegion.bottom],
      'thumb': fingerprint.thumb?.encode(),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (++_writesSinceTrim >= 500) {
      _writesSinceTrim = 0;
      await database.rawDelete(
        '''
DELETE FROM $_table WHERE url NOT IN (
  SELECT url FROM $_table ORDER BY updated_at DESC LIMIT ?
)''',
        <Object>[maximumEntries],
      );
    }
  }

  /// Number of cached fingerprints, for the settings/diagnostics UI.
  Future<int> count() async {
    final database = await _database();
    final rows = await database.rawQuery('SELECT COUNT(*) AS n FROM $_table');
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<void> clear() async {
    final database = await _database();
    await database.delete(_table);
  }
}

/// App-wide cache instance shared by every bookmark scan.
final SqliteBookmarkVisualFingerprintCache bookmarkVisualFingerprintCache =
    SqliteBookmarkVisualFingerprintCache();
