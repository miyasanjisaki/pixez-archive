import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pixez/network/api_client.dart';
import 'package:pixez/utils/bookmark_visual_search.dart';
import 'package:pixez/utils/image_perceptual_hash.dart';
import 'package:pixez/utils/pixiv_bookmark_visual_search.dart';

void main() {
  group('bookmark visual failure details', () {
    test('keeps the query-image limit aligned with local inspection', () {
      expect(maximumBookmarkFingerprintPixels, 32 * 1024 * 1024);
    });

    test('reports decode and timeout failures without request details', () {
      expect(
        describeBookmarkVisualSearchFailure(
          const BookmarkVisualQueryImageException(
            'private filename and dimensions',
          ),
        ),
        'Selected image could not be decoded for bookmark comparison',
      );
      expect(
        describeBookmarkVisualSearchFailure(
          TimeoutException('https://app-api.pixiv.net/private-token'),
        ),
        'Pixiv bookmark request timed out',
      );
    });

    test('does not blame malformed Pixiv data on the selected image', () {
      expect(
        describeBookmarkVisualSearchFailure(
          const FormatException('invalid next_url scope'),
        ),
        'Pixiv bookmark data could not be processed',
      );
    });

    test('classifies expired authentication without leaking the URL', () {
      final detail = describeBookmarkVisualSearchFailure(
        DioException(
          requestOptions: RequestOptions(
            path: 'https://app-api.pixiv.net/private-token',
          ),
          response: Response<void>(
            requestOptions: RequestOptions(path: '/bookmarks'),
            statusCode: 401,
          ),
          type: DioExceptionType.badResponse,
        ),
      );
      expect(detail, contains('login expired'));
      expect(detail, isNot(contains('private-token')));
    });
  });

  group('PixivCurrentUserBookmarkVisualSource', () {
    test(
      'sends first-page, max-bookmark, and legacy offset requests',
      () async {
        final adapter = _RecordingAdapter();
        final api = ApiClient();
        api.httpClient = Dio(BaseOptions(baseUrl: 'https://app-api.pixiv.net'))
          ..httpClientAdapter = adapter;
        final source = PixivCurrentUserBookmarkVisualSource(
          client: api,
          currentUserIdProvider: () => 42,
        );
        final token = BookmarkVisualCancellationToken();

        await source.loadPage(
          expectedUserId: 42,
          visibility: BookmarkVisibility.public,
          cursor: null,
          cancellationToken: token,
        );
        await source.loadPage(
          expectedUserId: 42,
          visibility: BookmarkVisibility.private,
          cursor: const BookmarkVisualPageCursor.maxBookmarkId(9001),
          cancellationToken: token,
        );
        await source.loadPage(
          expectedUserId: 42,
          visibility: BookmarkVisibility.public,
          cursor: const BookmarkVisualPageCursor.offset(30),
          cancellationToken: token,
        );

        expect(adapter.requests, hasLength(3));
        expect(adapter.requests[0].path, '/v1/user/bookmarks/illust');
        expect(adapter.requests[0].queryParameters, <String, Object>{
          'user_id': 42,
          'restrict': 'public',
        });
        expect(adapter.requests[1].queryParameters, <String, Object>{
          'user_id': 42,
          'restrict': 'private',
          'max_bookmark_id': 9001,
        });
        expect(adapter.requests[2].queryParameters, <String, Object>{
          'user_id': 42,
          'restrict': 'public',
          'offset': 30,
        });
      },
    );
  });

  group('FlutterBookmarkVisualFingerprintComputer', () {
    test('computes full and crop hashes from a candidate image', () async {
      final source = image.Image(width: 180, height: 240);
      for (var y = 0; y < source.height; y++) {
        for (var x = 0; x < source.width; x++) {
          final top = y < source.height ~/ 2;
          final value = top
              ? (x * 255 ~/ (source.width - 1))
              : ((source.width - 1 - x) * 255 ~/ (source.width - 1));
          // dHash compares horizontal luminance. Make the upper half strictly
          // increase and the lower half strictly decrease so the whole-image
          // hash is deliberately different from the upper-half query, while
          // the candidate's upper-region hash remains an exact match.
          source.setPixelRgb(x, y, value, value, value);
        }
      }
      final query = image.copyCrop(
        source,
        x: 0,
        y: 0,
        width: source.width,
        height: source.height ~/ 2,
      );
      final computer = FlutterBookmarkVisualFingerprintComputer();

      final queryFingerprint = await computer.compute(
        Uint8List.fromList(image.encodePng(query)),
      );
      final candidateFingerprint = await computer.compute(
        Uint8List.fromList(image.encodePng(source)),
      );

      expect(
        candidateFingerprint.regionDifferenceHashes.keys,
        unorderedEquals(<BookmarkVisualRegion>[
          BookmarkVisualRegion.full,
          BookmarkVisualRegion.top,
          BookmarkVisualRegion.bottom,
        ]),
      );
      expect(
        differenceHashDistance(
          queryFingerprint.differenceHash!,
          candidateFingerprint.differenceHash!,
        ),
        greaterThan(4),
      );
      expect(
        differenceHashDistance(
          queryFingerprint.differenceHash!,
          candidateFingerprint.regionDifferenceHashes[BookmarkVisualRegion
              .top]!,
        ),
        0,
      );
    });
  });

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

      expect(page.nextCursor, const BookmarkVisualPageCursor.offset(30));
      expect(page.works.map((work) => work.illustId), <int>[100, 140739814]);
      expect(page.works[0].images.single.url, contains('single-medium'));
      expect(page.works[1].images.map((image) => image.pageIndex), <int>[0, 1]);
      expect(page.works[1].images.map((image) => image.url), <String>[
        'https://i.pximg.net/140739814_p0_medium.jpg',
        'https://i.pximg.net/140739814_p1_medium.jpg',
      ]);
    });

    test('accepts the current max_bookmark_id cursor', () {
      final page = parsePixivBookmarkVisualPage(
        <String, dynamic>{
          'illusts': <dynamic>[],
          'next_url':
              'https://app-api.pixiv.net/v1/user/bookmarks/illust?user_id=42&restrict=public&max_bookmark_id=31827376703',
        },
        expectedUserId: 42,
        visibility: BookmarkVisibility.public,
      );

      expect(
        page.nextCursor,
        const BookmarkVisualPageCursor.maxBookmarkId(31827376703),
      );
    });

    test('rejects changed scope, endpoint, or duplicated cursor fields', () {
      const invalidNextUrls = <String>[
        'https://app-api.pixiv.net/v1/user/bookmarks/illust?user_id=99&restrict=public&offset=30',
        'https://app-api.pixiv.net/v1/user/bookmarks/illust?user_id=42&restrict=private&offset=30',
        'https://evil.example/v1/user/bookmarks/illust?user_id=42&restrict=public&offset=30',
        'https://app-api.pixiv.net/v1/user/bookmarks/novel?user_id=42&restrict=public&offset=30',
        'https://app-api.pixiv.net/v1/user/bookmarks/illust?restrict=public&offset=30',
        'https://app-api.pixiv.net/v1/user/bookmarks/illust?user_id=42&offset=30',
        'https://app-api.pixiv.net/v1/user/bookmarks/illust?user_id=42&restrict=public&offset=30&max_bookmark_id=29',
        'https://app-api.pixiv.net/v1/user/bookmarks/illust?user_id=42&restrict=public&offset=30&offset=60',
        'https://app-api.pixiv.net/v1/user/bookmarks/illust?user_id=42&restrict=public&max_bookmark_id=-1',
        'https://app-api.pixiv.net/v1/user/bookmarks/illust?user_id=42&restrict=public&offset=30&tag=private',
      ];

      for (final nextUrl in invalidNextUrls) {
        expect(
          () => parsePixivBookmarkVisualPage(
            <String, dynamic>{'illusts': <dynamic>[], 'next_url': nextUrl},
            expectedUserId: 42,
            visibility: BookmarkVisibility.public,
          ),
          throwsFormatException,
          reason: nextUrl,
        );
      }
    });
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{'illusts': <Object?>[], 'next_url': null}),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
