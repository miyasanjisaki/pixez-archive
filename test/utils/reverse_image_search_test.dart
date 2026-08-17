import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/reverse_image_search.dart';

void main() {
  group('reverse-image input byte limit', () {
    test('accepts only non-empty inputs through the exact 52 MiB boundary', () {
      expect(isReverseImageInputByteLengthAllowed(0), isFalse);
      expect(isReverseImageReportedByteLengthAllowed(-1), isFalse);
      expect(isReverseImageReportedByteLengthAllowed(0), isTrue);
      expect(
        isReverseImageInputByteLengthAllowed(maximumReverseImageInputBytes - 1),
        isTrue,
      );
      expect(
        isReverseImageInputByteLengthAllowed(maximumReverseImageInputBytes),
        isTrue,
      );
      expect(
        isReverseImageReportedByteLengthAllowed(maximumReverseImageInputBytes),
        isTrue,
      );
      expect(
        isReverseImageInputByteLengthAllowed(maximumReverseImageInputBytes + 1),
        isFalse,
      );
      expect(
        isReverseImageReportedByteLengthAllowed(
          maximumReverseImageInputBytes + 1,
        ),
        isFalse,
      );
    });
  });

  group('planReverseImageProbeRegions', () {
    test('keeps a full probe and overlapping side probes in bounds', () {
      final probes = planReverseImageProbeRegions(1000, 500);

      expect(probes.first.kind, ReverseImageProbeKind.full);
      expect(probes.first.width, 1000);
      expect(probes.first.height, 500);
      expect(
        probes.every(
          (probe) =>
              probe.x >= 0 &&
              probe.y >= 0 &&
              probe.x + probe.width <= 1000 &&
              probe.y + probe.height <= 500,
        ),
        isTrue,
      );

      final left = probes.singleWhere(
        (probe) => probe.kind == ReverseImageProbeKind.left,
      );
      final right = probes.singleWhere(
        (probe) => probe.kind == ReverseImageProbeKind.right,
      );
      expect(left.width, 700);
      expect(right.x, 300);
      expect(left.x + left.width - right.x, 400);
    });

    test('rejects invalid dimensions and fractions', () {
      expect(() => planReverseImageProbeRegions(0, 100), throwsArgumentError);
      expect(
        () => planReverseImageProbeRegions(100, 100, sideFraction: 0.5),
        throwsArgumentError,
      );
    });
  });

  group('planReverseImageProbeLayout', () {
    test('places an existing top half without cropping any source pixel', () {
      final layout = planReverseImageProbeLayout(
        640,
        360,
        ReverseImageProbeKind.inputTopHalf,
      );

      expect(layout.preservesWholeInput, isTrue);
      expect(
        [
          layout.source.x,
          layout.source.y,
          layout.source.width,
          layout.source.height,
        ],
        [0, 0, 640, 360],
      );
      expect([layout.canvasWidth, layout.canvasHeight], [640, 720]);
      expect([layout.destinationX, layout.destinationY], [0, 0]);
      expect([layout.outputWidth, layout.outputHeight], [640, 720]);
      expect(
        [layout.outputContentWidth, layout.outputContentHeight],
        [640, 360],
      );
      expect([layout.outputDestinationX, layout.outputDestinationY], [0, 0]);
    });

    test('places an existing bottom half in the lower canvas half', () {
      final layout = planReverseImageProbeLayout(
        640,
        360,
        ReverseImageProbeKind.inputBottomHalf,
      );

      expect(layout.preservesWholeInput, isTrue);
      expect(
        [layout.source.width, layout.source.height],
        [640, 360],
        reason: 'the half-image action must not enter the 70% crop path',
      );
      expect(layout.destinationY, 360);
      expect(layout.outputDestinationY, 360);
      expect(
        layout.outputDestinationY + layout.outputContentHeight,
        layout.outputHeight,
      );
    });

    test('keeps subject crop semantics separate from half-image padding', () {
      final crop = planReverseImageProbeLayout(
        640,
        360,
        ReverseImageProbeKind.top,
      );
      final half = planReverseImageProbeLayout(
        640,
        360,
        ReverseImageProbeKind.inputTopHalf,
      );

      expect(crop.source.height, 252);
      expect(crop.canvasHeight, 252);
      expect(crop.preservesWholeInput, isFalse);
      expect(half.source.height, 360);
      expect(half.canvasHeight, 720);
    });

    test('bounds the composed output before a canvas is allocated', () {
      final bottom = planReverseImageProbeLayout(
        3000,
        2000,
        ReverseImageProbeKind.inputBottomHalf,
      );
      final extreme = planReverseImageProbeLayout(
        100000,
        1,
        ReverseImageProbeKind.inputTopHalf,
      );

      expect([bottom.outputWidth, bottom.outputHeight], [1200, 1600]);
      expect(
        [bottom.outputContentWidth, bottom.outputContentHeight],
        [1200, 800],
      );
      expect(bottom.outputDestinationY, 800);
      for (final layout in [bottom, extreme]) {
        expect(layout.outputWidth, inInclusiveRange(1, 1600));
        expect(layout.outputHeight, inInclusiveRange(2, 1600));
        expect(layout.outputDestinationX, greaterThanOrEqualTo(0));
        expect(layout.outputDestinationY, greaterThanOrEqualTo(0));
        expect(
          layout.outputDestinationX + layout.outputContentWidth,
          lessThanOrEqualTo(layout.outputWidth),
        );
        expect(
          layout.outputDestinationY + layout.outputContentHeight,
          lessThanOrEqualTo(layout.outputHeight),
        );
      }
    });

    test('rejects dimensions that cannot represent both canvas halves', () {
      expect(
        () => planReverseImageProbeLayout(
          100,
          100,
          ReverseImageProbeKind.inputTopHalf,
          maximumOutputDimension: 1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('aggregateReverseImageHits', () {
    ReverseImageProviderHit hit({
      required int id,
      required double similarity,
      required String provider,
      required ReverseImageProbeKind probe,
      String? thumbnailUrl,
    }) => ReverseImageProviderHit(
      providerId: provider,
      probe: probe,
      illustId: id,
      similarity: similarity,
      sourceUrl: 'https://www.pixiv.net/artworks/$id',
      thumbnailUrl: thumbnailUrl,
    );

    test('orders by agreement but preserves the raw best similarity', () {
      final result = aggregateReverseImageHits([
        hit(
          id: 10,
          similarity: 55,
          provider: 'saucenao',
          probe: ReverseImageProbeKind.full,
        ),
        hit(
          id: 10,
          similarity: 52,
          provider: 'saucenao',
          probe: ReverseImageProbeKind.left,
        ),
        hit(
          id: 20,
          similarity: 58,
          provider: 'saucenao',
          probe: ReverseImageProbeKind.full,
        ),
      ]);

      expect(result.map((candidate) => candidate.illustId), [10, 20]);
      expect(result.first.bestSimilarity, 55);
      expect(result.first.rankScore, 59);
      expect(result.first.canAutoOpen, isFalse);
    });

    test('keeps a weak result only when independent evidence agrees', () {
      final result = aggregateReverseImageHits([
        hit(
          id: 10,
          similarity: 38,
          provider: 'saucenao',
          probe: ReverseImageProbeKind.full,
        ),
        hit(
          id: 10,
          similarity: 36,
          provider: 'saucenao',
          probe: ReverseImageProbeKind.center,
        ),
        hit(
          id: 20,
          similarity: 44,
          provider: 'saucenao',
          probe: ReverseImageProbeKind.full,
        ),
      ]);

      expect(result.map((candidate) => candidate.illustId), [10]);
    });

    test('never auto-opens from agreement boost alone', () {
      final result = aggregateReverseImageHits([
        hit(
          id: 10,
          similarity: 78,
          provider: 'saucenao',
          probe: ReverseImageProbeKind.full,
        ),
        hit(
          id: 10,
          similarity: 77,
          provider: 'ascii2d',
          probe: ReverseImageProbeKind.center,
        ),
      ]).single;

      expect(result.rankScore, greaterThanOrEqualTo(80));
      expect(result.canAutoOpen, isFalse);
    });

    test('preserves nullable provider thumbnails in aggregated evidence', () {
      const thumbnailUrl = 'https://cdn.example/thumbs/10.jpg';
      final result = aggregateReverseImageHits([
        hit(
          id: 10,
          similarity: 77,
          provider: 'saucenao',
          probe: ReverseImageProbeKind.full,
          thumbnailUrl: thumbnailUrl,
        ),
        hit(
          id: 10,
          similarity: 70,
          provider: 'iqdb',
          probe: ReverseImageProbeKind.center,
        ),
      ]).single;

      expect(result.evidence.first.thumbnailUrl, thumbnailUrl);
      expect(result.evidence.last.thumbnailUrl, isNull);
    });

    test('does not auto-open two nearly tied high-confidence works', () {
      final candidates = aggregateReverseImageHits([
        hit(
          id: 10,
          similarity: 90,
          provider: 'saucenao',
          probe: ReverseImageProbeKind.full,
        ),
        hit(
          id: 20,
          similarity: 89,
          provider: 'iqdb',
          probe: ReverseImageProbeKind.full,
        ),
      ]);

      expect(chooseReverseImageAutoOpenCandidate(candidates), isNull);
      expect(
        chooseReverseImageAutoOpenCandidate(candidates, minimumMargin: 1),
        candidates.first,
      );
    });

    test('does not auto-open over a stronger generic source', () {
      final candidates = aggregateReverseImageHits([
        hit(
          id: 10,
          similarity: 88,
          provider: 'saucenao',
          probe: ReverseImageProbeKind.full,
        ),
      ]);

      expect(
        chooseReverseImageAutoOpenCandidate(
          candidates,
          strongestExternalSimilarity: 95,
        ),
        isNull,
      );
      expect(
        chooseReverseImageAutoOpenCandidate(
          candidates,
          strongestExternalSimilarity: 70,
        ),
        candidates.first,
      );
    });

    test('provider interface carries bytes without defining transport', () {
      final query = ReverseImageQuery(
        bytes: Uint8List.fromList([1, 2, 3]),
        extension: 'jpg',
        probe: ReverseImageProbeKind.full,
      );

      expect(query.bytes, [1, 2, 3]);
      expect(query.probe, ReverseImageProbeKind.full);
    });

    test('continues when Sauce fails and IQDB returns a hit', () async {
      final query = ReverseImageQuery(
        bytes: Uint8List.fromList([1]),
        extension: 'jpg',
        probe: ReverseImageProbeKind.full,
      );
      final run = await runReverseImageProviders([
        _FakeProvider(
          'saucenao',
          const ReverseImageProviderResponse(
            serviceMessage: 'browser verification required',
          ),
        ),
        _FakeProvider(
          'iqdb',
          ReverseImageProviderResponse(
            hits: [
              hit(
                id: 42,
                similarity: 91,
                provider: 'iqdb',
                probe: ReverseImageProbeKind.full,
              ),
            ],
          ),
        ),
      ], query);

      expect(run.hits.single.illustId, 42);
      expect(run.successfulProviders, 1);
      expect(run.allProvidersFailed, isFalse);
    });

    test(
      'distinguishes valid empty responses from all-provider failure',
      () async {
        final query = ReverseImageQuery(
          bytes: Uint8List.fromList([1]),
          extension: 'jpg',
          probe: ReverseImageProbeKind.full,
        );
        final noMatch = await runReverseImageProviders([
          _FakeProvider('saucenao', const ReverseImageProviderResponse()),
          _FakeProvider('iqdb', const ReverseImageProviderResponse()),
        ], query);
        final failed = await runReverseImageProviders([
          _FakeProvider(
            'saucenao',
            const ReverseImageProviderResponse(serviceMessage: 'blocked'),
          ),
          _ThrowingProvider('iqdb'),
        ], query);

        expect(noMatch.hits, isEmpty);
        expect(noMatch.successfulProviders, 2);
        expect(noMatch.allProvidersFailed, isFalse);
        expect(failed.hits, isEmpty);
        expect(failed.allProvidersFailed, isTrue);
      },
    );
  });
}

class _FakeProvider implements ReverseImageSearchProvider {
  @override
  final String id;
  final ReverseImageProviderResponse response;

  const _FakeProvider(this.id, this.response);

  @override
  Future<ReverseImageProviderResponse> search(ReverseImageQuery query) async =>
      response;
}

class _ThrowingProvider implements ReverseImageSearchProvider {
  @override
  final String id;

  const _ThrowingProvider(this.id);

  @override
  Future<ReverseImageProviderResponse> search(ReverseImageQuery query) {
    throw StateError('offline');
  }
}
