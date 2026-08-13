import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/pixiv_image_identity.dart';

void main() {
  group('extractPixivIllustId', () {
    test('recognizes PixEz default and duplicate download names', () {
      expect(extractPixivIllustId(hints: ['123456789_p0.jpg']), 123456789);
      expect(
        extractPixivIllustId(hints: ['123456789_p2_master1200 (1).png']),
        123456789,
      );
    });

    test('recognizes an encoded Android picker display name', () {
      expect(
        extractPixivIllustId(
          hints: [
            'content://media/picker/0/com.android.providers.media.photopicker/'
                'media?displayName=98765432_p0.webp',
          ],
        ),
        98765432,
      );
      expect(
        extractPixivIllustId(hints: ['content://picker/87654321_p0%2Ejpg']),
        87654321,
      );
    });

    test('recognizes modern, legacy, and pximg links', () {
      expect(
        extractPixivIllustId(
          hints: ['https://www.pixiv.net/en/artworks/76543210'],
        ),
        76543210,
      );
      expect(
        extractPixivIllustId(
          hints: [
            'https://www.pixiv.net/member_illust.php?mode=medium&amp;'
                'illust_id=65432109',
          ],
        ),
        65432109,
      );
      expect(
        extractPixivIllustId(
          hints: [
            'https://i.pximg.net/img-original/img/2026/01/02/03/04/05/'
                '54321098_p0.jpg',
          ],
        ),
        54321098,
      );
    });

    test('reads Pixiv references from JPEG or PNG textual metadata', () {
      final jpegComment = Uint8List.fromList(
        latin1.encode(
          '\u00ff\u00d8Exif\x00\x00UserComment\x00'
          'https://www.pixiv.net/artworks/43210987\u00ff\u00d9',
        ),
      );
      final pngText = Uint8List.fromList(
        utf8.encode('\u0089PNG\r\n\u001a\nTitle\x0032109876_p0.png IEND'),
      );

      expect(extractPixivIllustId(bytes: jpegComment), 43210987);
      expect(extractPixivIllustId(bytes: pngText), 32109876);
    });

    test('does not guess IDs from unrelated camera names or timestamps', () {
      expect(extractPixivIllustId(hints: ['IMG_20260813_165200.jpg']), isNull);
      expect(extractPixivIllustId(hints: ['Screenshot_123456789.png']), isNull);
      expect(extractPixivIllustId(hints: ['artwork-20260813.png']), isNull);
      expect(extractPixivIllustId(hints: ['my_pixiv_12345.jpg']), isNull);
      expect(extractPixivIllustId(hints: ['Pixiv ID: 12345678']), 12345678);
    });
  });

  test('extractPixivIllustIdsFromText deduplicates SauceNAO links', () {
    const html = '''
      <a href="https://www.pixiv.net/artworks/12345678">modern</a>
      <a href="https://www.pixiv.net/member_illust.php?illust_id=12345678">old</a>
      <a href="https://www.pixiv.net/artworks/23456789">second</a>
    ''';

    expect(extractPixivIllustIdsFromText(html), [12345678, 23456789]);
  });
}
