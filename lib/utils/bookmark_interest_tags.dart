import 'package:pixez/models/illust_bookmark_tags_response.dart';

class BookmarkInterestTag {
  final String name;
  final int count;

  const BookmarkInterestTag({required this.name, required this.count});
}

Future<List<BookmarkTag>> collectBookmarkTagPages({
  required Future<IllustBookmarkTagsResponse> Function() firstPage,
  required Future<IllustBookmarkTagsResponse> Function(String url) nextPage,
  int maxPages = 50,
}) async {
  if (maxPages <= 0) return const <BookmarkTag>[];

  final result = <BookmarkTag>[];
  final seenUrls = <String>{};
  var response = await firstPage();

  for (var page = 0; page < maxPages; page++) {
    result.addAll(response.bookmarkTags);
    if (page + 1 >= maxPages) {
      break;
    }
    final nextUrl = response.nextUrl?.trim();
    if (nextUrl == null || nextUrl.isEmpty || !seenUrls.add(nextUrl)) {
      break;
    }
    response = await nextPage(nextUrl);
  }
  return result;
}

List<BookmarkInterestTag> mergeBookmarkInterestTags({
  required Iterable<BookmarkTag> remoteTags,
  required Iterable<String> localTags,
  int limit = 80,
}) {
  if (limit <= 0) return const <BookmarkInterestTag>[];

  final counts = <String, int>{};
  for (final remoteTag in remoteTags) {
    final name = remoteTag.name.trim();
    if (_isUsefulInterestTag(name)) {
      counts[name] = (counts[name] ?? 0) + remoteTag.count;
    }
  }
  for (final rawTag in localTags) {
    final name = rawTag.trim();
    if (_isUsefulInterestTag(name)) {
      counts.putIfAbsent(name, () => 0);
    }
  }

  final result =
      counts.entries
          .map(
            (entry) => BookmarkInterestTag(name: entry.key, count: entry.value),
          )
          .toList()
        ..sort((a, b) {
          final countOrder = b.count.compareTo(a.count);
          return countOrder != 0 ? countOrder : a.name.compareTo(b.name);
        });
  return result.take(limit).toList(growable: false);
}

bool _isUsefulInterestTag(String tag) {
  if (tag.isEmpty) return false;
  final normalized = tag.toLowerCase();
  return normalized != '未分類' &&
      normalized != '未分类' &&
      normalized != 'uncategorized';
}
