import 'package:dio/dio.dart';
import 'package:pixez/models/bookmark_library.dart';
import 'package:pixez/network/api_client.dart';

/// App-wide bookmark library backed by the signed-in account's API client.
final BookmarkLibrary bookmarkLibrary = BookmarkLibrary(
  loadPage: (userId, restrict, nextUrl) async {
    final Response response = nextUrl == null
        ? await apiClient.getBookmarksIllust(userId, restrict.name, null)
        : await apiClient.getNext(nextUrl);
    final data = response.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw const FormatException('Pixiv returned an invalid bookmark page');
  },
);
