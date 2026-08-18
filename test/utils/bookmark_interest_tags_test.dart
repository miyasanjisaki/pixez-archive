import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/models/illust_bookmark_tags_response.dart';
import 'package:pixez/utils/bookmark_interest_tags.dart';

void main() {
  test('collects every bookmark tag page and stops repeated cursors', () async {
    final requested = <String>[];
    final tags = await collectBookmarkTagPages(
      firstPage: () async => IllustBookmarkTagsResponse(
        bookmarkTags: [BookmarkTag(name: 'first', count: 2)],
        nextUrl: 'page-2',
      ),
      nextPage: (url) async {
        requested.add(url);
        return IllustBookmarkTagsResponse(
          bookmarkTags: [BookmarkTag(name: 'second', count: 1)],
          nextUrl: 'page-2',
        );
      },
    );

    expect(requested, const ['page-2']);
    expect(tags.map((tag) => tag.name), const ['first', 'second']);
  });

  test('does not request a page beyond the configured limit', () async {
    var nextPageCalls = 0;
    final tags = await collectBookmarkTagPages(
      maxPages: 1,
      firstPage: () async => IllustBookmarkTagsResponse(
        bookmarkTags: [BookmarkTag(name: 'first', count: 2)],
        nextUrl: 'page-2',
      ),
      nextPage: (_) async {
        nextPageCalls++;
        return IllustBookmarkTagsResponse(
          bookmarkTags: [BookmarkTag(name: 'unexpected', count: 1)],
          nextUrl: null,
        );
      },
    );

    expect(nextPageCalls, 0);
    expect(tags.map((tag) => tag.name), const ['first']);
  });

  test('merges public private and local interests by popularity', () {
    final result = mergeBookmarkInterestTags(
      remoteTags: [
        BookmarkTag(name: 'Azur Lane', count: 4),
        BookmarkTag(name: 'Blue Archive', count: 8),
        BookmarkTag(name: 'Azur Lane', count: 3),
        BookmarkTag(name: '未分類', count: 99),
      ],
      localTags: const [' Blue Archive ', 'local only', ''],
    );

    expect(result.map((tag) => '${tag.name}:${tag.count}'), const [
      'Blue Archive:8',
      'Azur Lane:7',
      'local only:0',
    ]);
  });
}
