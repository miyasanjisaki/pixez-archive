import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pixez/utils/bookmark_visual_search.dart';
import 'package:pixez/utils/visual_descriptor.dart';

img.Image _artwork(int seed) {
  final random = math.Random(seed);
  final canvas = img.Image(width: 500, height: 700);
  img.fill(canvas, color: img.ColorRgb8(240, 236, 228));
  for (var i = 0; i < 35; i++) {
    final color = img.ColorRgb8(
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    );
    img.fillCircle(
      canvas,
      x: random.nextInt(500),
      y: random.nextInt(700),
      radius: 20 + random.nextInt(80),
      color: color,
    );
  }
  return canvas;
}

String _sha(String c) => List<String>.filled(64, c).join();

class _Source implements CurrentUserBookmarkVisualSource {
  final List<BookmarkVisualWork> works;
  _Source(this.works);

  @override
  int? get currentUserId => 42;

  @override
  Future<BookmarkVisualPage> loadPage({
    required int expectedUserId,
    required BookmarkVisibility visibility,
    required BookmarkVisualPageCursor? cursor,
    required BookmarkVisualCancellationToken cancellationToken,
  }) async => BookmarkVisualPage(
    works: visibility == BookmarkVisibility.public ? works : const [],
  );
}

class _Fetcher implements BookmarkVisualImageFetcher {
  int downloads = 0;

  @override
  Future<Uint8List> fetch(
    BookmarkVisualImageReference image,
    BookmarkVisualCancellationToken cancellationToken,
  ) async {
    downloads++;
    return Uint8List.fromList(<int>[int.parse(image.url)]);
  }
}

class _Computer implements BookmarkVisualFingerprintComputer {
  final Map<int, BookmarkVisualFingerprint> byByte;
  _Computer(this.byByte);

  @override
  Future<BookmarkVisualFingerprint> compute(Uint8List bytes) async =>
      byByte[bytes.single]!;
}

class _MemoryCache implements BookmarkVisualFingerprintCache {
  final Map<String, BookmarkVisualFingerprint> entries = {};

  @override
  Future<BookmarkVisualFingerprint?> lookup(String imageUrl) async =>
      entries[imageUrl];

  @override
  Future<void> store(String imageUrl, BookmarkVisualFingerprint fp) async {
    entries[imageUrl] = fp;
  }
}

void main() {
  final target = _artwork(1);
  final topHalf = img.copyCrop(target, x: 0, y: 0, width: 500, height: 350);

  // dHash values are deliberately far apart: only the window correlation
  // can connect the half image to its source.
  final fingerprints = <int, BookmarkVisualFingerprint>{
    0: BookmarkVisualFingerprint(
      sha256: _sha('0'),
      differenceHash: '0000000000000000',
      thumb: computeVisualThumb(topHalf),
    ),
    1: BookmarkVisualFingerprint(
      sha256: _sha('1'),
      differenceHash: 'ffffffffffffffff',
      thumb: computeVisualThumb(target),
    ),
    for (var seed = 2; seed <= 6; seed++)
      seed: BookmarkVisualFingerprint(
        sha256: _sha('$seed'),
        differenceHash: 'f0f0f0f0f0f0f0f0',
        thumb: computeVisualThumb(_artwork(seed)),
      ),
  };
  final works = <BookmarkVisualWork>[
    for (var id = 2; id <= 6; id++)
      BookmarkVisualWork(
        illustId: 1000 + id,
        images: [BookmarkVisualImageReference(pageIndex: 0, url: '$id')],
      ),
    const BookmarkVisualWork(
      illustId: 140739814,
      images: [BookmarkVisualImageReference(pageIndex: 0, url: '1')],
    ),
  ];

  test('a half image is matched through window correlation', () async {
    final service = BookmarkVisualSearchService(
      source: _Source(works),
      imageFetcher: _Fetcher(),
      fingerprintComputer: _Computer(fingerprints),
    );
    final result = await service.search(
      queryBytes: Uint8List.fromList(<int>[0]),
    );
    expect(result.status, BookmarkVisualSearchStatus.matched);
    expect(result.match?.illustId, 140739814);
    expect(result.match?.similarity, greaterThan(0.9));
    expect(result.candidates.first.illustId, 140739814);
  });

  test('a second scan uses cached fingerprints instead of downloads', () async {
    final cache = _MemoryCache();
    final fetcher = _Fetcher();
    BookmarkVisualSearchService service() => BookmarkVisualSearchService(
      source: _Source(works),
      imageFetcher: fetcher,
      fingerprintComputer: _Computer(fingerprints),
      fingerprintCache: cache,
      allowEarlyExactPerceptualMatch: false,
    );
    await service().search(queryBytes: Uint8List.fromList(<int>[0]));
    expect(fetcher.downloads, works.length);

    BookmarkVisualProgress? last;
    final again = await service().search(
      queryBytes: Uint8List.fromList(<int>[0]),
      onProgress: (progress) => last = progress,
    );
    expect(fetcher.downloads, works.length, reason: 'no new downloads');
    expect(last?.imagesFromCache, works.length);
    expect(again.match?.illustId, 140739814);
  });
}
