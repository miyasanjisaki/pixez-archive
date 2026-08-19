import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/illust_bookmark_tags.dart';

void main() {
  test('normalizes bookmark tags without changing their order', () {
    expect(
      normalizeIllustBookmarkTags(const [
        ' foo ',
        '',
        'bar',
        'foo',
        '  ',
        'baz',
      ]),
      const ['foo', 'bar', 'baz'],
    );
  });

  test('encodes Pixiv bookmark tags as one space-separated form value', () {
    expect(encodeIllustBookmarkTags(const [' foo ', 'bar', 'foo']), 'foo bar');
    expect(encodeIllustBookmarkTags(const []), isNull);
    expect(encodeIllustBookmarkTags(null), isNull);
  });
}
