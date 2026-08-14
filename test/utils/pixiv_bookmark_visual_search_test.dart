import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/bookmark_visual_search.dart';
import 'package:pixez/utils/pixiv_bookmark_visual_search.dart';

void main() {
  group('parsePixivBookmarkVisualPage', () {
    test('selects API medium URLs for single and every meta page', () {
      final page = parsePixivBookmarkVisualPage(
        <String, dynamic>{
          'illusts': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 100,
              'visible': true,
              'image_urls': <String, String>{
                'square_medium':
                    'https://i.pximg.net/square-should-not-be-used.jpg',
                'medium': 'https://i.pximg.net/single-medium.jpg',
              },
              'meta_pages': <dynamic>[],
            },
            <String, dynamic>{
              'id': 140739814,
              'visible': true,
              'image_urls': <String, String>{
                'medium': 'https://i.pximg.net/cover-medium.jpg',
              },
              'meta_pages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'image_urls': <String, String>{
                    'medium': 'https://i.pximg.net/140739814_p0_medium.jpg',
                  },
                },
                <String, dynamic>{
                  'image_urls': <String, String>{
                    'medium': 'https://i.pximg.net/140739814_p1_medium.jpg',
                  },
                },
              ],
            },
            <String, dynamic>{
              'id': 300,
              'visible': false,
              'image_urls': <String, String>{
                'medium': 'https://i.pximg.net/invisible.jpg',
              },
              'meta_pages': <dynamic>[],
            },
          ],
          'next_url':
              'https://app-api.pixiv.net/v1/user/bookmarks/illust?user_id=42&restrict=private&offset=30',
        },
        expectedUserId: 42,
        visibility: BookmarkVisibility.private,
      );

      expect(page.nextOffset, 30);
      expect(page.works.map((work) => work.illustId), <int>[100, 140739814]);
      expect(page.works[0].images.single.url, contains('single-medium'));
      expect(page.works[1].images.map((image) => image.pageIndex), <int>[0, 1]);
      expect(page.works[1].images.map((image) => image.url), <String>[
        'https://i.pximg.net/140739814_p0_medium.jpg',
        'https://i.pximg.net/140739814_p1_medium.jpg',
      ]);
    });

    test('rejects a next page that changes account or visibility', () {
      expect(
        () => parsePixivBookmarkVisualPage(
          <String, dynamic>{
            'illusts': <dynamic>[],
            'next_url':
                'https://app-api.pixiv.net/v1/user/bookmarks/illust?user_id=99&restrict=public&offset=30',
          },
          expectedUserId: 42,
          visibility: BookmarkVisibility.public,
        ),
        throwsFormatException,
      );
      expect(
        () => parsePixivBookmarkVisualPage(
          <String, dynamic>{
            'illusts': <dynamic>[],
            'next_url':
                'https://app-api.pixiv.net/v1/user/bookmarks/illust?user_id=42&restrict=private&offset=30',
          },
          expectedUserId: 42,
          visibility: BookmarkVisibility.public,
        ),
        throwsFormatException,
      );
    });
  });
}
