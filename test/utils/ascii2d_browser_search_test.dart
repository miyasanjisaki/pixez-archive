import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/ascii2d_browser_search.dart';

void main() {
  group('validateAscii2dUpload', () {
    test('recognizes supported signatures without trusting an extension', () {
      expect(
        validateAscii2dUpload(
          Uint8List.fromList([0xff, 0xd8, 0xff, 0x00]),
        ).format,
        Ascii2dImageFormat.jpeg,
      );
      expect(
        validateAscii2dUpload(
          Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        ).format,
        Ascii2dImageFormat.png,
      );
      expect(
        validateAscii2dUpload(
          Uint8List.fromList('RIFF1234WEBP'.codeUnits),
        ).format,
        Ascii2dImageFormat.webp,
      );
    });

    test('rejects unknown, empty, and oversized inputs', () {
      expect(validateAscii2dUpload(Uint8List(0)).isValid, isFalse);
      expect(
        validateAscii2dUpload(Uint8List.fromList([1, 2, 3])).isValid,
        isFalse,
      );
      expect(
        validateAscii2dUpload(Uint8List(ascii2dMaximumUploadBytes + 1)).isValid,
        isFalse,
      );
    });
  });

  test('trust checks require the exact Ascii2D HTTPS origin', () {
    expect(isTrustedAscii2dUri(Uri.parse('https://ascii2d.net/')), isTrue);
    expect(isTrustedAscii2dUri(Uri.parse('https://www.ascii2d.net/')), isTrue);
    expect(isTrustedAscii2dUri(Uri.parse('http://ascii2d.net/')), isFalse);
    expect(
      isTrustedAscii2dUri(Uri.parse('https://ascii2d.net.evil.test/')),
      isFalse,
    );
  });

  test('extracts only Pixiv artwork URLs', () {
    expect(
      pixivArtworkIdFromUri(
        Uri.parse('https://www.pixiv.net/en/artworks/140739814?ref=ascii2d'),
      ),
      140739814,
    );
    expect(
      pixivArtworkIdFromUri(Uri.parse('https://www.pixiv.net/i/140739814')),
      140739814,
    );
    expect(
      pixivArtworkIdFromUri(
        Uri.parse(
          'https://www.pixiv.net/member_illust.php?mode=medium&illust_id=140739814',
        ),
      ),
      140739814,
    );
    expect(
      pixivArtworkIdFromUri(
        Uri.parse('https://evilpixiv.net/artworks/140739814'),
      ),
      isNull,
    );
    expect(
      pixivArtworkIdFromUri(Uri.parse('https://www.pixiv.net/users/123')),
      isNull,
    );
  });

  test('switches between color and feature result pages', () {
    final color = Uri.parse('https://ascii2d.net/search/color/abc123');
    expect(
      ascii2dResultModeUri(color, Ascii2dResultMode.feature).toString(),
      'https://ascii2d.net/search/bovw/abc123',
    );
    expect(
      ascii2dResultModeUri(
        Uri.parse('https://ascii2d.net/'),
        Ascii2dResultMode.color,
      ),
      isNull,
    );
  });

  test('upload grant is one-shot, short-lived, and origin-bound', () {
    final gate = Ascii2dUploadGate(lifetime: const Duration(seconds: 30));
    final now = DateTime.utc(2026, 8, 15, 8);
    gate.arm(now);
    expect(
      gate.consume(
        pageUri: Uri.parse('https://ascii2d.net/'),
        now: now.add(const Duration(seconds: 10)),
      ),
      isTrue,
    );
    expect(
      gate.consume(pageUri: Uri.parse('https://ascii2d.net/'), now: now),
      isFalse,
    );

    gate.arm(now);
    expect(
      gate.consume(
        pageUri: Uri.parse('https://example.com/'),
        now: now.add(const Duration(seconds: 1)),
      ),
      isFalse,
    );

    gate.arm(now);
    expect(
      gate.consume(
        pageUri: Uri.parse('https://ascii2d.net/'),
        now: now.add(const Duration(seconds: 31)),
      ),
      isFalse,
    );
  });
}
