import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/reverse_image_search.dart';
import 'package:pixez/utils/reverse_image_session.dart';

void main() {
  ReverseImageProviderHit hit({
    required String provider,
    required double similarity,
    required String sourceUrl,
    int? illustId,
    String? thumbnailUrl,
    ReverseImageProbeKind probe = ReverseImageProbeKind.full,
  }) => ReverseImageProviderHit(
    providerId: provider,
    probe: probe,
    illustId: illustId,
    similarity: similarity,
    sourceUrl: sourceUrl,
    thumbnailUrl: thumbnailUrl,
  );

  test('keeps the complete deduplicated list instead of five rows', () {
    final input = <ReverseImageProviderHit>[
      for (var id = 1; id <= 8; id++)
        hit(
          provider: 'iqdb',
          similarity: 90 - id.toDouble(),
          illustId: 100000 + id,
          sourceUrl: 'https://www.pixiv.net/artworks/${100000 + id}',
        ),
    ];

    final result = buildReverseImageDisplayCandidates(input);

    expect(result, hasLength(8));
    expect(result.first.illustId, 100001);
    expect(result.last.illustId, 100008);
  });

  test('merges provider and crop evidence while retaining a thumbnail', () {
    final result = buildReverseImageDisplayCandidates([
      hit(
        provider: 'saucenao',
        similarity: 71,
        illustId: 140739814,
        sourceUrl: 'https://www.pixiv.net/artworks/140739814',
        thumbnailUrl: 'https://saucenao.com/thumb.jpg',
      ),
      hit(
        provider: 'iqdb',
        similarity: 69,
        illustId: 140739814,
        sourceUrl: 'https://www.pixiv.net/artworks/140739814',
        probe: ReverseImageProbeKind.left,
      ),
    ]).single;

    expect(result.evidence, hasLength(2));
    expect(result.providerIds, {'saucenao', 'iqdb'});
    expect(result.probes, {
      ReverseImageProbeKind.full,
      ReverseImageProbeKind.left,
    });
    expect(result.thumbnailUrl, 'https://saucenao.com/thumb.jpg');
    expect(result.confidence, ReverseImageCandidateConfidence.medium);
  });

  test('keeps a weak Pixiv candidate only with independent evidence', () {
    final single = buildReverseImageDisplayCandidates([
      hit(
        provider: 'saucenao',
        similarity: 38,
        illustId: 19871999,
        sourceUrl: 'https://www.pixiv.net/artworks/19871999',
      ),
    ]);
    final repeated = buildReverseImageDisplayCandidates([
      hit(
        provider: 'saucenao',
        similarity: 38,
        illustId: 19871999,
        sourceUrl: 'https://www.pixiv.net/artworks/19871999',
      ),
      hit(
        provider: 'iqdb',
        similarity: 36,
        illustId: 19871999,
        sourceUrl: 'https://www.pixiv.net/artworks/19871999',
      ),
    ]).single;

    expect(single, isEmpty);
    expect(repeated.illustId, 19871999);
    expect(repeated.confidence, ReverseImageCandidateConfidence.low);
  });

  test('deduplicates a generic source by URL and keeps its best hit', () {
    final result = buildReverseImageDisplayCandidates([
      hit(
        provider: 'saucenao',
        similarity: 55,
        sourceUrl: 'https://example.com/post/1',
      ),
      hit(
        provider: 'iqdb',
        similarity: 72,
        sourceUrl: 'https://example.com/post/1',
        thumbnailUrl: 'https://safe.iqdb.org/thumb.jpg',
      ),
    ]).single;

    expect(result.illustId, isNull);
    expect(result.bestSimilarity, 72);
    expect(result.evidence, hasLength(2));
    expect(result.thumbnailUrl, 'https://safe.iqdb.org/thumb.jpg');
  });

  test('selects Pixiv square-medium candidate previews only', () {
    expect(
      extractPixivCandidateThumbnailUrl({
        'illust': {
          'page_count': 1,
          'image_urls': {
            'square_medium':
                'https://i.pximg.net/c/360x360_70/img-master/example.jpg',
            'medium': 'https://i.pximg.net/medium.jpg',
          },
        },
      }),
      contains('/360x360_70/'),
    );
    expect(
      extractPixivCandidateThumbnailUrl({
        'illust': {
          'page_count': 1,
          'image_urls': {
            'square_medium': 'https://tracker.example/candidate.jpg',
            'medium': 'http://i.pximg.net/insecure.jpg',
          },
        },
      }),
      isNull,
    );
    expect(
      extractPixivCandidateThumbnailUrl({
        'illust': {
          'page_count': 1,
          'image_urls': {
            'square_medium': 'https://tracker.example/candidate.jpg',
            'medium': 'https://i.pximg.net/medium-fallback.jpg',
          },
        },
      }),
      'https://i.pximg.net/medium-fallback.jpg',
    );
    expect(
      extractPixivCandidateThumbnailUrl({
        'illust': {
          'page_count': 2,
          'image_urls': {
            'square_medium': 'https://i.pximg.net/p0-would-be-wrong.jpg',
          },
        },
      }),
      isNull,
    );
  });
}
