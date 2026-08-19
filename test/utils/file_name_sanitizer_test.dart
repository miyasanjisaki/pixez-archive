import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/file_name_sanitizer.dart';

void main() {
  group('sanitizeFileNameComponent', () {
    test('removes path and platform-reserved characters', () {
      expect(
        sanitizeFileNameComponent('a/b\\c:d*e?f"g<h>i|j'),
        'a_b_c_d_e_f_g_h_i_j',
      );
    });

    test('uses a safe fallback for empty and traversal-only names', () {
      expect(sanitizeFileNameComponent('  ...  '), 'untitled');
      expect(sanitizeFileNameComponent('', fallback: '42_p0.jpg'), '42_p0.jpg');
    });

    test('prefixes Windows device names', () {
      expect(sanitizeFileNameComponent('CON'), '_CON');
      expect(sanitizeFileNameComponent('nul.png'), '_nul.png');
      expect(sanitizeFileNameComponent('COM9.txt'), '_COM9.txt');
    });

    test('trims trailing dots and spaces', () {
      expect(sanitizeFileNameComponent('title.   '), 'title');
    });

    test('preserves a short extension while truncating', () {
      final result = sanitizeFileNameComponent(
        '${List.filled(30, 'a').join()}.png',
        maxLength: 12,
      );
      expect(result, 'aaaaaaaa.png');
      expect(result.runes.length, 12);
    });
  });

  group('sanitizeRelativeFilePath', () {
    test('keeps safe subdirectories', () {
      expect(
        sanitizeRelativeFilePath('artist_1/image.jpg'),
        'artist_1/image.jpg',
      );
    });

    test('neutralizes legacy traversal and absolute path components', () {
      expect(sanitizeRelativeFilePath('../outside.jpg'), '_/outside.jpg');
      expect(
        sanitizeRelativeFilePath(r'C:\temp\outside.jpg'),
        'C_/temp/outside.jpg',
      );
    });
  });

  group('inferImageFileExtension', () {
    test('reads the URL path instead of the query string', () {
      expect(
        inferImageFileExtension('https://i.pximg.net/a/IMAGE.PNG?token=.jpg'),
        '.png',
      );
    });

    test('normalizes jpeg and falls back safely', () {
      expect(inferImageFileExtension('https://example.test/a.jpeg'), '.jpg');
      expect(inferImageFileExtension('not an image'), '.jpg');
    });
  });
}
