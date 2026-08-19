import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pixez/models/download_identity_index.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('computes a stable SHA-256 image identity', () {
    final bytes = Uint8List.fromList(utf8.encode('pixez-image'));

    expect(
      computeImageSha256(bytes),
      'c049f1af8adaf68b72a9bd7ba7612d88628611262ce3cd9abcf622c13b1021c7',
    );
  });

  test(
    'stores exact identities and prunes to the configured bound',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final databaseDirectory = await databaseFactoryFfi.getDatabasesPath();
      final databasePath = path.join(
        databaseDirectory,
        'download_image_identity_test.db',
      );
      await databaseFactoryFfi.deleteDatabase(databasePath);

      final index = DownloadIdentityIndex(
        maximumEntries: 2,
        databaseName: 'download_image_identity_test.db',
      );
      try {
        final first = Uint8List.fromList([1]);
        final second = Uint8List.fromList([2]);
        final third = Uint8List.fromList([3]);
        await index.rememberBytes(
          bytes: first,
          illustId: 11111111,
          pageIndex: 0,
          fileName: 'custom.jpg',
        );
        await index.rememberBytes(
          bytes: second,
          illustId: 22222222,
          pageIndex: 1,
          differenceHash: '0000000000000001',
        );
        await index.rememberBytes(
          bytes: third,
          illustId: 33333333,
          pageIndex: 2,
          differenceHash: 'ffffffffffffffff',
        );

        expect(await index.findBytes(first), isNull);
        expect((await index.findBytes(second))?.illustId, 22222222);
        expect((await index.findBytes(third))?.pageIndex, 2);
        final nearDuplicate = await index.findPerceptualHash(
          '0000000000000000',
          maximumDistance: 4,
          minimumDistanceGap: 2,
        );
        expect(nearDuplicate?.identity.illustId, 22222222);
        expect(nearDuplicate?.distance, 1);
      } finally {
        await index.close();
        await databaseFactoryFfi.deleteDatabase(databasePath);
      }
    },
    testOn: 'windows || linux || mac-os',
  );

  test(
    'returns null when perceptual neighbours from different works are ambiguous',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final databaseDirectory = await databaseFactoryFfi.getDatabasesPath();
      final databasePath = path.join(
        databaseDirectory,
        'download_image_identity_ambiguous_test.db',
      );
      await databaseFactoryFfi.deleteDatabase(databasePath);

      final index = DownloadIdentityIndex(
        databaseName: 'download_image_identity_ambiguous_test.db',
      );
      try {
        await index.rememberBytes(
          bytes: Uint8List.fromList([1]),
          illustId: 11111111,
          pageIndex: 0,
          differenceHash: '0000000000000001',
        );
        await index.rememberBytes(
          bytes: Uint8List.fromList([2]),
          illustId: 22222222,
          pageIndex: 0,
          differenceHash: '0000000000000002',
        );

        expect(
          await index.findPerceptualHash(
            '0000000000000000',
            maximumDistance: 4,
            minimumDistanceGap: 2,
          ),
          isNull,
        );
      } finally {
        await index.close();
        await databaseFactoryFfi.deleteDatabase(databasePath);
      }
    },
    testOn: 'windows || linux || mac-os',
  );

  test(
    'migrates the exact-only version 1 database without losing identities',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final databaseDirectory = await databaseFactoryFfi.getDatabasesPath();
      final databaseName = 'download_image_identity_migration_test.db';
      final databasePath = path.join(databaseDirectory, databaseName);
      await databaseFactoryFfi.deleteDatabase(databasePath);

      final legacy = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (database, version) async {
            await database.execute('''
CREATE TABLE download_image_identity (
  sha256 TEXT PRIMARY KEY,
  illust_id INTEGER NOT NULL,
  page_index INTEGER NOT NULL,
  file_name TEXT,
  updated_at INTEGER NOT NULL
)
''');
          },
        ),
      );
      const digest =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      await legacy.insert('download_image_identity', <String, Object?>{
        'sha256': digest,
        'illust_id': 12345678,
        'page_index': 0,
        'file_name': 'legacy.jpg',
        'updated_at': 1,
      });
      await legacy.close();

      final index = DownloadIdentityIndex(databaseName: databaseName);
      try {
        final exact = await index.findDigest(digest);
        expect(exact?.illustId, 12345678);
        expect(exact?.differenceHash, isNull);

        await index.rememberDigest(
          sha256:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          illustId: 87654321,
          pageIndex: 0,
          differenceHash: '0123456789abcdef',
        );
        expect(
          (await index.findPerceptualHash(
            '0123456789abcdef',
            maximumDistance: 0,
            minimumDistanceGap: 1,
          ))?.identity.illustId,
          87654321,
        );
      } finally {
        await index.close();
        await databaseFactoryFfi.deleteDatabase(databasePath);
      }
    },
    testOn: 'windows || linux || mac-os',
  );
}
