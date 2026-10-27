import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/booru_pixiv_resolver.dart';
import 'package:pixez/utils/reverse_image_search.dart';

ReverseImageProviderHit _hit(String url, {double similarity = 90, int? id}) =>
    ReverseImageProviderHit(
      providerId: 'iqdb',
      probe: ReverseImageProbeKind.full,
      illustId: id,
      similarity: similarity,
      sourceUrl: url,
    );

void main() {
  group('parseBooruPostUrl', () {
    test('recognises supported post pages', () {
      expect(
        parseBooruPostUrl('https://danbooru.donmai.us/posts/123456'),
        const BooruPostRef(BooruSite.danbooru, 123456),
      );
      expect(
        parseBooruPostUrl('https://danbooru.donmai.us/post/show/77'),
        const BooruPostRef(BooruSite.danbooru, 77),
      );
      expect(
        parseBooruPostUrl('https://yande.re/post/show/9'),
        const BooruPostRef(BooruSite.yandere, 9),
      );
      expect(
        parseBooruPostUrl('https://konachan.com/post/show/5'),
        const BooruPostRef(BooruSite.konachan, 5),
      );
    });

    test('ignores unrelated pages', () {
      expect(parseBooruPostUrl('https://danbooru.donmai.us/posts'), isNull);
      expect(parseBooruPostUrl('https://example.com/posts/1'), isNull);
      expect(parseBooruPostUrl('not a url'), isNull);
    });
  });

  group('extractPixivIdFromBooruJson', () {
    test('prefers Danbooru pixiv_id', () {
      expect(
        extractPixivIdFromBooruJson(<String, dynamic>{
          'pixiv_id': 140739814,
          'source': 'https://twitter.com/x/status/1',
        }),
        140739814,
      );
    });

    test('reads a Pixiv source from Moebooru list responses', () {
      expect(
        extractPixivIdFromBooruJson(<dynamic>[
          <String, dynamic>{
            'source':
                'https://i.pximg.net/img-original/img/2024/01/01/00/00/00/98765432_p0.png',
          },
        ]),
        98765432,
      );
      expect(
        extractPixivIdFromBooruJson(<String, dynamic>{
          'source': 'https://www.pixiv.net/artworks/1234567',
        }),
        1234567,
      );
    });

    test('never trusts a non-Pixiv source', () {
      expect(
        extractPixivIdFromBooruJson(<String, dynamic>{
          'pixiv_id': null,
          'source': 'https://example.com/12345678_p0.png',
        }),
        isNull,
      );
      expect(extractPixivIdFromBooruJson(const <dynamic>[]), isNull);
    });
  });

  test('resolver fills Pixiv IDs and leaves failures untouched', () async {
    final requested = <Uri>[];
    final resolver = BooruPixivResolver(
      fetchJson: (uri, _) async {
        requested.add(uri);
        if (uri.host == 'yande.re')
          throw DioException(requestOptions: RequestOptions());
        return <String, dynamic>{'pixiv_id': 555555};
      },
    );
    final hits = await resolver.resolve(<ReverseImageProviderHit>[
      _hit('https://danbooru.donmai.us/posts/1'),
      _hit('https://yande.re/post/show/2'),
      _hit('https://danbooru.donmai.us/posts/3', similarity: 20),
      _hit('https://www.pixiv.net/artworks/4', id: 4),
    ]);
    expect(hits[0].illustId, 555555);
    expect(hits[0].sourceUrl, 'https://danbooru.donmai.us/posts/1');
    expect(hits[1].illustId, isNull);
    expect(hits[2].illustId, isNull, reason: 'below the lookup threshold');
    expect(hits[3].illustId, 4);
    expect(requested.length, 2);
  });
}
