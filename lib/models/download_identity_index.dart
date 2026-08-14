import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart';
import 'package:pixez/utils/image_perceptual_hash.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _identityTable = 'download_image_identity';
const String _columnDigest = 'sha256';
const String _columnIllustId = 'illust_id';
const String _columnPageIndex = 'page_index';
const String _columnFileName = 'file_name';
const String _columnUpdatedAt = 'updated_at';
const String _columnDifferenceHash = 'dhash';

/// Computes exact and near-duplicate fingerprints in one background isolate.
///
/// The map is isolate-sendable. A `null` dHash means the image was unsupported
/// or exceeded the conservative decode bounds; exact SHA-256 remains valid.
Map<String, String?> computeDownloadImageFingerprints(Uint8List bytes) =>
    <String, String?>{
      _columnDigest: computeImageSha256(bytes),
      _columnDifferenceHash: tryComputeDifferenceHash(bytes),
    };

/// Computes the exact-content identity used for locally downloaded images.
///
/// This is a top-level function so callers can run it with Flutter's `compute`
/// helper instead of hashing a large image on the UI isolate.
String computeImageSha256(Uint8List bytes) => sha256.convert(bytes).toString();

class DownloadImageIdentity {
  final String sha256;
  final int illustId;
  final int pageIndex;
  final String? fileName;
  final int updatedAt;
  final String? differenceHash;

  const DownloadImageIdentity({
    required this.sha256,
    required this.illustId,
    required this.pageIndex,
    required this.fileName,
    required this.updatedAt,
    this.differenceHash,
  });

  factory DownloadImageIdentity.fromMap(Map<String, Object?> map) {
    return DownloadImageIdentity(
      sha256: map[_columnDigest]! as String,
      illustId: map[_columnIllustId]! as int,
      pageIndex: map[_columnPageIndex]! as int,
      fileName: map[_columnFileName] as String?,
      updatedAt: map[_columnUpdatedAt]! as int,
      differenceHash: map[_columnDifferenceHash] as String?,
    );
  }
}

class DownloadPerceptualIdentityMatch {
  final DownloadImageIdentity identity;
  final int distance;

  const DownloadPerceptualIdentityMatch({
    required this.identity,
    required this.distance,
  });

  double get similarity => 1 - distance / differenceHashBitCount;
}

/// A bounded, app-local mapping from exact image bytes to their Pixiv source.
///
/// The database intentionally contains no image bytes. Keeping only a SHA-256
/// digest and source identity makes lookups cheap and prevents this auxiliary
/// index from growing without limit.
class DownloadIdentityIndex {
  static const int defaultMaximumEntries = 4096;

  final int maximumEntries;
  final String databaseName;
  Future<Database>? _opening;
  int _lastUpdatedAt = 0;

  DownloadIdentityIndex({
    this.maximumEntries = defaultMaximumEntries,
    this.databaseName = 'download_image_identity.db',
  }) : assert(maximumEntries > 0),
       assert(databaseName != '');

  Future<Database> _database() => _opening ??= _open();

  Future<Database> _open() async {
    final databasesPath = await getDatabasesPath();
    return openDatabase(
      join(databasesPath, databaseName),
      version: 2,
      onCreate: (database, version) async {
        await database.execute('''
CREATE TABLE $_identityTable (
  $_columnDigest TEXT PRIMARY KEY,
  $_columnIllustId INTEGER NOT NULL,
  $_columnPageIndex INTEGER NOT NULL,
  $_columnFileName TEXT,
  $_columnUpdatedAt INTEGER NOT NULL,
  $_columnDifferenceHash TEXT
)
''');
        await database.execute(
          'CREATE INDEX download_image_identity_updated_at '
          'ON $_identityTable ($_columnUpdatedAt DESC)',
        );
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await database.execute(
            'ALTER TABLE $_identityTable '
            'ADD $_columnDifferenceHash TEXT',
          );
        }
      },
    );
  }

  Future<void> rememberDigest({
    required String sha256,
    required int illustId,
    required int pageIndex,
    String? fileName,
    String? differenceHash,
  }) async {
    if (illustId <= 0 || pageIndex < 0 || !_isSha256(sha256)) return;
    final database = await _database();
    final now = DateTime.now().microsecondsSinceEpoch;
    final updatedAt = now > _lastUpdatedAt ? now : _lastUpdatedAt + 1;
    _lastUpdatedAt = updatedAt;
    await database.transaction((transaction) async {
      await transaction.insert(_identityTable, <String, Object?>{
        _columnDigest: sha256.toLowerCase(),
        _columnIllustId: illustId,
        _columnPageIndex: pageIndex,
        _columnFileName: fileName,
        _columnUpdatedAt: updatedAt,
        _columnDifferenceHash:
            differenceHash != null && isValidDifferenceHash(differenceHash)
            ? differenceHash.trim().toLowerCase()
            : null,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await transaction.rawDelete(
        '''
DELETE FROM $_identityTable
WHERE $_columnDigest NOT IN (
  SELECT $_columnDigest
  FROM $_identityTable
  ORDER BY $_columnUpdatedAt DESC, rowid DESC
  LIMIT ?
)
''',
        <Object>[maximumEntries],
      );
    });
  }

  Future<void> rememberBytes({
    required Uint8List bytes,
    required int illustId,
    required int pageIndex,
    String? fileName,
    String? differenceHash,
  }) {
    return rememberDigest(
      sha256: computeImageSha256(bytes),
      illustId: illustId,
      pageIndex: pageIndex,
      fileName: fileName,
      differenceHash: differenceHash,
    );
  }

  Future<DownloadImageIdentity?> findDigest(String sha256) async {
    if (!_isSha256(sha256)) return null;
    final database = await _database();
    final rows = await database.query(
      _identityTable,
      where: '$_columnDigest = ?',
      whereArgs: <Object>[sha256.toLowerCase()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DownloadImageIdentity.fromMap(rows.first);
  }

  Future<DownloadImageIdentity?> findBytes(Uint8List bytes) {
    return findDigest(computeImageSha256(bytes));
  }

  /// Finds one unambiguous local near-duplicate by 64-bit dHash.
  ///
  /// This is intentionally limited to resized/re-encoded copies. It is not a
  /// crop or partial-image search. Thresholds are required so the caller owns
  /// their calibration; a close runner-up from another illustration returns
  /// `null` rather than guessing.
  Future<DownloadPerceptualIdentityMatch?> findPerceptualHash(
    String differenceHash, {
    required int maximumDistance,
    required int minimumDistanceGap,
  }) async {
    if (!isValidDifferenceHash(differenceHash)) return null;
    final database = await _database();
    final rows = await database.query(
      _identityTable,
      where: '$_columnDifferenceHash IS NOT NULL',
      orderBy: '$_columnUpdatedAt DESC',
      limit: maximumEntries,
    );
    final identities = rows.map(DownloadImageIdentity.fromMap).toList();
    final match = findUniqueDifferenceHashMatch<int>(
      differenceHash,
      identities.map(
        (identity) => DifferenceHashReference<int>(
          hash: identity.differenceHash!,
          value: identity.illustId,
        ),
      ),
      maximumDistance: maximumDistance,
      minimumDistanceGap: minimumDistanceGap,
    );
    if (match == null) return null;

    DownloadImageIdentity? bestIdentity;
    var bestDistance = differenceHashBitCount + 1;
    for (final identity in identities) {
      if (identity.illustId != match.value) continue;
      final distance = differenceHashDistance(
        differenceHash,
        identity.differenceHash!,
      );
      if (distance < bestDistance) {
        bestIdentity = identity;
        bestDistance = distance;
      }
    }
    if (bestIdentity == null) return null;
    return DownloadPerceptualIdentityMatch(
      identity: bestIdentity,
      distance: bestDistance,
    );
  }

  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) await (await opening).close();
  }
}

bool _isSha256(String value) =>
    RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(value);

final DownloadIdentityIndex downloadIdentityIndex = DownloadIdentityIndex();
