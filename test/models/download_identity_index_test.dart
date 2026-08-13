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
        );
        await index.rememberBytes(
          bytes: third,
          illustId: 33333333,
          pageIndex: 2,
        );

        expect(await index.findBytes(first), isNull);
        expect((await index.findBytes(second))?.illustId, 22222222);
        expect((await index.findBytes(third))?.pageIndex, 2);
      } finally {
        await index.close();
        await databaseFactoryFfi.deleteDatabase(databasePath);
      }
    },
    testOn: 'windows || linux || mac-os',
  );
}
