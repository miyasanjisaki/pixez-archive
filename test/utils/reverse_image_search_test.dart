import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/reverse_image_search.dart';

void main() {
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

  group('aggregateReverseImageHits', () {
    ReverseImageProviderHit hit({
      required int id,
      required double similarity,
      required String provider,
      required ReverseImageProbeKind probe,
    }) => ReverseImageProviderHit(
      providerId: provider,
      probe: probe,
      illustId: id,
      similarity: similarity,
      sourceUrl: 'https://www.pixiv.net/artworks/$id',
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
