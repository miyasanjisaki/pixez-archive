import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/bookmark_visual_search.dart';

void main() {
  group('BookmarkVisualSearchService', () {
    test(
      'synthetic state flow finds a private-page candidate and caches only after confirmation',
      () async {
        final source = _FakeSource(
          pages: <String, BookmarkVisualPage>{
            'public:first': _page(<BookmarkVisualWork>[
              _work(11, <String>['public-decoy']),
            ], nextMaxBookmarkId: 901),
            'public:max:901': _page(const <BookmarkVisualWork>[]),
            'private:first': _page(<BookmarkVisualWork>[
              _work(22, <String>['private-decoy']),
            ], nextMaxBookmarkId: 801),
            'private:max:801': _page(<BookmarkVisualWork>[
              _work(140739814, <String>['target-p0', 'target-p1']),
            ]),
          },
        );
        final fetcher = _FakeFetcher(<String, int>{
          'public-decoy': 1,
          'private-decoy': 2,
          'target-p0': 3,
          'target-p1': 4,
        }, delay: const Duration(milliseconds: 5));
        final fingerprints = _FakeFingerprintComputer(<int, _Fingerprint>{
          99: _fingerprint('a', '0123456789abcdef'),
          1: _fingerprint('b', 'ffffffffffffffff'),
          2: _fingerprint('c', '1111111111111111'),
          // Different bytes but the same global image layout as the query.
          3: _fingerprint('d', '0123456789abcdef'),
          4: _fingerprint('e', '0123456789abcdee'),
        });
        final sink = _FakeSink();
        final service = BookmarkVisualSearchService(
          source: source,
          imageFetcher: fetcher,
          fingerprintComputer: fingerprints,
          limits: const BookmarkVisualSearchLimits(downloadConcurrency: 2),
        );

        final result = await service.search(
          queryBytes: Uint8List.fromList(<int>[99]),
          queryFileName: 'wechat-copy.jpg',
        );

        expect(result.status, BookmarkVisualSearchStatus.matched);
        expect(result.match?.illustId, 140739814);
        expect(result.match?.pageIndex, 0);
        expect(result.match?.kind, BookmarkVisualMatchKind.exactPerceptual);
        expect(result.match?.distance, 0);
        expect(result.requiresConfirmation, isTrue);
        expect(result.scanComplete, isFalse);
        expect(source.calls, <String>[
          'public:first',
          'private:first',
          'public:max:901',
          'private:max:801',
        ]);
        expect(fetcher.maximumActive, lessThanOrEqualTo(2));
        expect(result.progress.imagesCompared, 4);
        expect(sink.records, isEmpty);
        final confirmed =
            await BookmarkVisualMatchConfirmer(
              fingerprintComputer: fingerprints,
              identitySink: sink,
            ).confirm(
              result: result,
              queryBytes: Uint8List.fromList(<int>[99]),
              queryFileName: 'wechat-copy.jpg',
            );
        expect(confirmed, isTrue);
        expect(sink.records, hasLength(1));
        expect(sink.records.single.illustId, 140739814);
        expect(sink.records.single.pageIndex, 0);
        expect(sink.records.single.fileName, 'wechat-copy.jpg');
        expect(sink.records.single.sha256, _sha('a'));
        expect(sink.records.single.differenceHash, '0123456789abcdef');
      },
    );

    test(
      'rejects equal dHash matches from different works as ambiguous',
      () async {
        final source = _FakeSource(
          pages: <String, BookmarkVisualPage>{
            'public:first': _page(<BookmarkVisualWork>[
              _work(100, <String>['first']),
              _work(200, <String>['second']),
            ]),
          },
        );
        final sink = _FakeSink();
        final service = BookmarkVisualSearchService(
          source: source,
          imageFetcher: _FakeFetcher(<String, int>{'first': 1, 'second': 2}),
          fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
            9: _fingerprint('9', '0000000000000000'),
            1: _fingerprint('1', '0000000000000000'),
            2: _fingerprint('2', '0000000000000000'),
          }),
        );

        final result = await service.search(
          queryBytes: Uint8List.fromList(<int>[9]),
        );

        expect(result.status, BookmarkVisualSearchStatus.ambiguous);
        expect(result.match, isNull);
        expect(result.candidates.map((candidate) => candidate.illustId), <int>[
          100,
          200,
        ]);
        expect(sink.records, isEmpty);
      },
    );

    test('rejects a near match without the configured runner-up gap', () async {
      final source = _FakeSource(
        pages: <String, BookmarkVisualPage>{
          'public:first': _page(<BookmarkVisualWork>[
            _work(100, <String>['best']),
            _work(200, <String>['runner-up']),
          ]),
        },
      );
      final service = BookmarkVisualSearchService(
        source: source,
        imageFetcher: _FakeFetcher(<String, int>{'best': 1, 'runner-up': 2}),
        fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
          9: _fingerprint('9', '0000000000000000'),
          1: _fingerprint('1', '0000000000000001'),
          2: _fingerprint('2', '0000000000000003'),
        }),
        limits: const BookmarkVisualSearchLimits(
          maximumDistance: 4,
          minimumDistanceGap: 2,
        ),
      );

      final result = await service.search(
        queryBytes: Uint8List.fromList(<int>[9]),
      );

      expect(result.status, BookmarkVisualSearchStatus.ambiguous);
      expect(result.candidates[0].distance, 1);
      expect(result.candidates[1].distance, 2);
    });

    test(
      'retains a runner-up just outside the match threshold when checking the gap',
      () async {
        final source = _FakeSource(
          pages: <String, BookmarkVisualPage>{
            'public:first': _page(<BookmarkVisualWork>[
              _work(100, <String>['best']),
              _work(200, <String>['runner-up']),
            ]),
          },
        );
        final service = BookmarkVisualSearchService(
          source: source,
          imageFetcher: _FakeFetcher(<String, int>{'best': 1, 'runner-up': 2}),
          fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
            9: _fingerprint('9', '0000000000000000'),
            1: _fingerprint('1', '000000000000000f'),
            2: _fingerprint('2', '000000000000001f'),
          }),
          limits: const BookmarkVisualSearchLimits(
            maximumDistance: 4,
            minimumDistanceGap: 2,
          ),
        );

        final result = await service.search(
          queryBytes: Uint8List.fromList(<int>[9]),
        );

        expect(result.status, BookmarkVisualSearchStatus.ambiguous);
        expect(result.match, isNull);
        expect(result.candidates.map((candidate) => candidate.distance), <int?>[
          4,
          5,
        ]);
      },
    );

    test(
      'checks both visibility pages in a round before an early dHash-zero result',
      () async {
        final source = _FakeSource(
          pages: <String, BookmarkVisualPage>{
            'public:first': _page(<BookmarkVisualWork>[
              _work(100, <String>['public-collision']),
            ]),
            'private:first': _page(<BookmarkVisualWork>[
              _work(200, <String>['private-target']),
            ]),
          },
        );
        final service = BookmarkVisualSearchService(
          source: source,
          imageFetcher: _FakeFetcher(<String, int>{
            'public-collision': 1,
            'private-target': 2,
          }),
          fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
            9: _fingerprint('9', '0123456789abcdef'),
            1: _fingerprint('1', '0123456789abcdef'),
            2: _fingerprint('2', '0123456789abcdef'),
          }),
        );

        final result = await service.search(
          queryBytes: Uint8List.fromList(<int>[9]),
        );

        expect(source.calls, <String>['public:first', 'private:first']);
        expect(result.status, BookmarkVisualSearchStatus.ambiguous);
        expect(result.match, isNull);
      },
    );

    test(
      'does not early-return a dHash-zero candidate without its gap',
      () async {
        final source = _FakeSource(
          pages: <String, BookmarkVisualPage>{
            'public:first': _page(<BookmarkVisualWork>[
              _work(100, <String>['best']),
            ]),
            'private:first': _page(<BookmarkVisualWork>[
              _work(200, <String>['runner-up']),
            ]),
          },
        );
        final service = BookmarkVisualSearchService(
          source: source,
          imageFetcher: _FakeFetcher(<String, int>{'best': 1, 'runner-up': 2}),
          fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
            9: _fingerprint('9', '0000000000000000'),
            1: _fingerprint('1', '0000000000000000'),
            2: _fingerprint('2', '0000000000000001'),
          }),
          limits: const BookmarkVisualSearchLimits(
            maximumDistance: 4,
            minimumDistanceGap: 2,
          ),
        );

        final result = await service.search(
          queryBytes: Uint8List.fromList(<int>[9]),
        );

        expect(result.status, BookmarkVisualSearchStatus.ambiguous);
        expect(result.match, isNull);
        expect(result.candidates.map((candidate) => candidate.distance), <int?>[
          0,
          1,
        ]);
      },
    );

    test(
      'full scan keeps a later true candidate after an earlier dHash collision',
      () async {
        final source = _FakeSource(
          pages: <String, BookmarkVisualPage>{
            'public:first': _page(<BookmarkVisualWork>[
              _work(100, <String>['early-collision']),
            ], nextOffset: 30),
            'private:first': _page(
              const <BookmarkVisualWork>[],
              nextOffset: 30,
            ),
            'public:30': _page(<BookmarkVisualWork>[
              _work(140739814, <String>['later-target']),
            ]),
            'private:30': _page(const <BookmarkVisualWork>[]),
          },
        );
        final service = BookmarkVisualSearchService(
          source: source,
          imageFetcher: _FakeFetcher(<String, int>{
            'early-collision': 1,
            'later-target': 2,
          }),
          fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
            9: _fingerprint('9', '0123456789abcdef'),
            1: _fingerprint('1', '0123456789abcdef'),
            2: _fingerprint('2', '0123456789abcdef'),
          }),
          limits: const BookmarkVisualSearchLimits(
            maximumPagesPerVisibility: 2,
          ),
          allowEarlyExactPerceptualMatch: false,
        );

        final result = await service.search(
          queryBytes: Uint8List.fromList(<int>[9]),
        );

        expect(source.calls, <String>[
          'public:first',
          'private:first',
          'public:30',
          'private:30',
        ]);
        expect(result.status, BookmarkVisualSearchStatus.ambiguous);
        expect(
          result.candidates.map((candidate) => candidate.illustId).toSet(),
          <int>{100, 140739814},
        );
        expect(result.scanComplete, isTrue);
      },
    );

    test(
      'cursor repetition tracks both the cursor kind and numeric value',
      () async {
        final source = _FakeSource(
          pages: <String, BookmarkVisualPage>{
            'public:first': _page(
              const <BookmarkVisualWork>[],
              nextMaxBookmarkId: 30,
            ),
            'private:first': _page(const <BookmarkVisualWork>[]),
            'public:max:30': _page(
              const <BookmarkVisualWork>[],
              nextOffset: 30,
            ),
            'public:30': _page(const <BookmarkVisualWork>[]),
          },
        );
        final service = BookmarkVisualSearchService(
          source: source,
          imageFetcher: _FakeFetcher(const <String, int>{}),
          fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
            9: _fingerprint('9', '0000000000000000'),
          }),
        );

        final result = await service.search(
          queryBytes: Uint8List.fromList(<int>[9]),
        );

        expect(result.status, BookmarkVisualSearchStatus.notFound);
        expect(result.scanComplete, isTrue);
        expect(source.calls, <String>[
          'public:first',
          'private:first',
          'public:max:30',
          'public:30',
        ]);
      },
    );

    test('fails safely when Pixiv repeats the same typed cursor', () async {
      final source = _FakeSource(
        pages: <String, BookmarkVisualPage>{
          'public:first': _page(
            const <BookmarkVisualWork>[],
            nextMaxBookmarkId: 30,
          ),
          'private:first': _page(const <BookmarkVisualWork>[]),
          'public:max:30': _page(
            const <BookmarkVisualWork>[],
            nextMaxBookmarkId: 30,
          ),
        },
      );
      final service = BookmarkVisualSearchService(
        source: source,
        imageFetcher: _FakeFetcher(const <String, int>{}),
        fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
          9: _fingerprint('9', '0000000000000000'),
        }),
      );

      final result = await service.search(
        queryBytes: Uint8List.fromList(<int>[9]),
      );

      expect(result.status, BookmarkVisualSearchStatus.failed);
      expect(result.error, isA<FormatException>());
      expect(source.calls, <String>[
        'public:first',
        'private:first',
        'public:max:30',
      ]);
    });

    test('fails before paging when the query cannot produce a dHash', () async {
      final source = _FakeSource(
        pages: <String, BookmarkVisualPage>{
          'public:first': _page(const <BookmarkVisualWork>[]),
        },
      );
      final service = BookmarkVisualSearchService(
        source: source,
        imageFetcher: _FakeFetcher(const <String, int>{}),
        fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
          9: _Fingerprint(_sha('9'), null),
        }),
      );

      final result = await service.search(
        queryBytes: Uint8List.fromList(<int>[9]),
      );

      expect(result.status, BookmarkVisualSearchStatus.failed);
      expect(result.error, isA<FormatException>());
      expect(source.calls, isEmpty);
    });

    test(
      'counts an undecodable non-SHA candidate as an incomplete image failure',
      () async {
        final source = _FakeSource(
          pages: <String, BookmarkVisualPage>{
            'public:first': _page(<BookmarkVisualWork>[
              _work(100, <String>['undecodable']),
            ]),
          },
        );
        final service = BookmarkVisualSearchService(
          source: source,
          imageFetcher: _FakeFetcher(<String, int>{'undecodable': 1}),
          fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
            9: _fingerprint('9', '0123456789abcdef'),
            1: _Fingerprint(_sha('1'), null),
          }),
        );

        final result = await service.search(
          queryBytes: Uint8List.fromList(<int>[9]),
        );

        expect(result.status, BookmarkVisualSearchStatus.incomplete);
        expect(result.progress.imagesCompared, 0);
        expect(result.progress.imageFailures, 1);
        expect(result.scanComplete, isFalse);
      },
    );

    test('exact bytes outrank perceptual neighbours', () async {
      final source = _FakeSource(
        pages: <String, BookmarkVisualPage>{
          'public:first': _page(<BookmarkVisualWork>[
            _work(100, <String>['near']),
            _work(200, <String>['exact']),
          ]),
        },
      );
      final service = BookmarkVisualSearchService(
        source: source,
        imageFetcher: _FakeFetcher(<String, int>{'near': 1, 'exact': 2}),
        fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
          9: _fingerprint('a', '0000000000000000'),
          1: _fingerprint('1', '0000000000000001'),
          2: _fingerprint('a', 'ffffffffffffffff'),
        }),
      );

      final result = await service.search(
        queryBytes: Uint8List.fromList(<int>[9]),
      );

      expect(result.status, BookmarkVisualSearchStatus.matched);
      expect(result.match?.illustId, 200);
      expect(result.match?.kind, BookmarkVisualMatchKind.exactBytes);
      expect(source.calls, <String>['public:first']);
    });

    test(
      'a failed public image does not block an exact private-first-page result',
      () async {
        final source = _FakeSource(
          pages: <String, BookmarkVisualPage>{
            'public:first': _page(<BookmarkVisualWork>[
              _work(100, <String>['broken']),
            ], nextOffset: 30),
            'private:first': _page(<BookmarkVisualWork>[
              _work(140739814, <String>['private-target']),
            ], nextOffset: 30),
          },
        );
        final service = BookmarkVisualSearchService(
          source: source,
          imageFetcher: _FakeFetcher(<String, int>{'private-target': 1}),
          fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
            9: _fingerprint('9', '0123456789abcdef'),
            1: _fingerprint('1', '0123456789abcdef'),
          }),
        );

        final result = await service.search(
          queryBytes: Uint8List.fromList(<int>[9]),
        );

        expect(result.status, BookmarkVisualSearchStatus.matched);
        expect(result.match?.illustId, 140739814);
        expect(result.match?.visibility, BookmarkVisibility.private);
        expect(result.match?.distance, 0);
        expect(result.progress.imageFailures, 1);
        expect(result.scanComplete, isFalse);
        expect(result.requiresConfirmation, isTrue);
        expect(source.calls, <String>['public:first', 'private:first']);
      },
    );

    test('reports page limits without caching a partial candidate', () async {
      final source = _FakeSource(
        pages: <String, BookmarkVisualPage>{
          'public:first': _page(<BookmarkVisualWork>[
            _work(100, <String>['public']),
          ], nextOffset: 30),
          'private:first': _page(<BookmarkVisualWork>[
            _work(200, <String>['private']),
          ], nextOffset: 30),
        },
      );
      final sink = _FakeSink();
      final service = BookmarkVisualSearchService(
        source: source,
        imageFetcher: _FakeFetcher(<String, int>{'public': 1, 'private': 2}),
        fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
          9: _fingerprint('9', '0000000000000000'),
          1: _fingerprint('1', '0000000000000000'),
          2: _fingerprint('2', 'ffffffffffffffff'),
        }),
        limits: const BookmarkVisualSearchLimits(maximumPagesPerVisibility: 1),
        allowEarlyExactPerceptualMatch: false,
      );

      final result = await service.search(
        queryBytes: Uint8List.fromList(<int>[9]),
      );

      expect(result.status, BookmarkVisualSearchStatus.limitReached);
      expect(source.calls, <String>['public:first', 'private:first']);
      expect(result.candidates.single.illustId, 100);
      expect(sink.records, isEmpty);
    });

    test(
      'cancellation stops queued image work and does not write the index',
      () async {
        final source = _FakeSource(
          pages: <String, BookmarkVisualPage>{
            'public:first': _page(<BookmarkVisualWork>[
              _work(100, <String>['a', 'b', 'c']),
            ]),
          },
        );
        final sink = _FakeSink();
        final token = BookmarkVisualCancellationToken();
        final service = BookmarkVisualSearchService(
          source: source,
          imageFetcher: _FakeFetcher(<String, int>{
            'a': 1,
            'b': 2,
            'c': 3,
          }, delay: const Duration(milliseconds: 5)),
          fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
            9: _fingerprint('9', '0000000000000000'),
            1: _fingerprint('1', '0000000000000000'),
            2: _fingerprint('2', '0000000000000000'),
            3: _fingerprint('3', '0000000000000000'),
          }),
          limits: const BookmarkVisualSearchLimits(downloadConcurrency: 1),
        );

        final result = await service.search(
          queryBytes: Uint8List.fromList(<int>[9]),
          cancellationToken: token,
          onProgress: (progress) {
            if (progress.imagesCompared == 1) token.cancel();
          },
        );

        expect(result.status, BookmarkVisualSearchStatus.cancelled);
        expect(result.progress.imagesCompared, 1);
        expect(sink.records, isEmpty);
      },
    );

    test('cancellation is propagated to an in-flight page source', () async {
      final source = _BlockingPageSource();
      final token = BookmarkVisualCancellationToken();
      final service = BookmarkVisualSearchService(
        source: source,
        imageFetcher: _FakeFetcher(const <String, int>{}),
        fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
          9: _fingerprint('9', '0000000000000000'),
        }),
      );

      final resultFuture = service.search(
        queryBytes: Uint8List.fromList(<int>[9]),
        cancellationToken: token,
      );
      await source.started.future;
      token.cancel();
      final result = await resultFuture;

      expect(result.status, BookmarkVisualSearchStatus.cancelled);
    });

    test(
      'aborts if the selected account changes after a page request',
      () async {
        final source = _FakeSource(
          pages: <String, BookmarkVisualPage>{
            'public:first': _page(const <BookmarkVisualWork>[]),
          },
          changeAccountAfterLoads: 1,
        );
        final service = BookmarkVisualSearchService(
          source: source,
          imageFetcher: _FakeFetcher(const <String, int>{}),
          fingerprintComputer: _FakeFingerprintComputer(<int, _Fingerprint>{
            9: _fingerprint('9', '0000000000000000'),
          }),
        );

        final result = await service.search(
          queryBytes: Uint8List.fromList(<int>[9]),
        );

        expect(result.status, BookmarkVisualSearchStatus.accountChanged);
        expect(source.calls, <String>['public:first']);
      },
    );
  });
}

BookmarkVisualPage _page(
  List<BookmarkVisualWork> works, {
  int? nextOffset,
  int? nextMaxBookmarkId,
}) {
  assert(nextOffset == null || nextMaxBookmarkId == null);
  return BookmarkVisualPage(
    works: works,
    nextCursor: nextOffset != null
        ? BookmarkVisualPageCursor.offset(nextOffset)
        : nextMaxBookmarkId != null
        ? BookmarkVisualPageCursor.maxBookmarkId(nextMaxBookmarkId)
        : null,
  );
}

BookmarkVisualWork _work(int illustId, List<String> urls) {
  return BookmarkVisualWork(
    illustId: illustId,
    images: <BookmarkVisualImageReference>[
      for (var index = 0; index < urls.length; index++)
        BookmarkVisualImageReference(pageIndex: index, url: urls[index]),
    ],
  );
}

_Fingerprint _fingerprint(String shaCharacter, String differenceHash) {
  return _Fingerprint(_sha(shaCharacter), differenceHash);
}

String _sha(String character) => List<String>.filled(64, character).join();

class _Fingerprint {
  final String sha256;
  final String? differenceHash;

  const _Fingerprint(this.sha256, this.differenceHash);
}

class _FakeFingerprintComputer implements BookmarkVisualFingerprintComputer {
  final Map<int, _Fingerprint> fingerprints;

  const _FakeFingerprintComputer(this.fingerprints);

  @override
  Future<BookmarkVisualFingerprint> compute(Uint8List bytes) async {
    final fingerprint = fingerprints[bytes.single];
    if (fingerprint == null) throw StateError('Missing fake fingerprint');
    return BookmarkVisualFingerprint(
      sha256: fingerprint.sha256,
      differenceHash: fingerprint.differenceHash,
    );
  }
}

class _FakeSource implements CurrentUserBookmarkVisualSource {
  final Map<String, BookmarkVisualPage> pages;
  final int? changeAccountAfterLoads;
  final List<String> calls = <String>[];
  int? _currentUserId = 42;

  _FakeSource({required this.pages, this.changeAccountAfterLoads});

  @override
  int? get currentUserId => _currentUserId;

  @override
  Future<BookmarkVisualPage> loadPage({
    required int expectedUserId,
    required BookmarkVisibility visibility,
    required BookmarkVisualPageCursor? cursor,
    required BookmarkVisualCancellationToken cancellationToken,
  }) async {
    if (expectedUserId != _currentUserId) {
      throw const BookmarkVisualAuthorizationException('account changed');
    }
    final key = '${visibility.name}:${_cursorLabel(cursor)}';
    calls.add(key);
    if (changeAccountAfterLoads == calls.length) _currentUserId = 43;
    return pages[key] ?? _page(const <BookmarkVisualWork>[]);
  }
}

class _FakeFetcher implements BookmarkVisualImageFetcher {
  final Map<String, int> byteByUrl;
  final Duration delay;
  int active = 0;
  int maximumActive = 0;

  _FakeFetcher(this.byteByUrl, {this.delay = Duration.zero});

  @override
  Future<Uint8List> fetch(
    BookmarkVisualImageReference image,
    BookmarkVisualCancellationToken cancellationToken,
  ) async {
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      final value = byteByUrl[image.url];
      if (value == null) throw StateError('Missing fake image');
      return Uint8List.fromList(<int>[value]);
    } finally {
      active--;
    }
  }
}

class _BlockingPageSource implements CurrentUserBookmarkVisualSource {
  final Completer<void> started = Completer<void>();

  @override
  int? get currentUserId => 42;

  @override
  Future<BookmarkVisualPage> loadPage({
    required int expectedUserId,
    required BookmarkVisibility visibility,
    required BookmarkVisualPageCursor? cursor,
    required BookmarkVisualCancellationToken cancellationToken,
  }) {
    final completer = Completer<BookmarkVisualPage>();
    void cancel() {
      if (!completer.isCompleted) {
        completer.completeError(StateError('page request cancelled'));
      }
    }

    cancellationToken.addListener(cancel);
    if (!started.isCompleted) started.complete();
    return completer.future.whenComplete(
      () => cancellationToken.removeListener(cancel),
    );
  }
}

String _cursorLabel(BookmarkVisualPageCursor? cursor) {
  if (cursor == null) return 'first';
  return switch (cursor.kind) {
    BookmarkVisualPageCursorKind.offset => cursor.value.toString(),
    BookmarkVisualPageCursorKind.maxBookmarkId => 'max:${cursor.value}',
  };
}

class _FakeSink implements BookmarkVisualIdentitySink {
  final List<BookmarkVisualIndexRecord> records = <BookmarkVisualIndexRecord>[];

  @override
  Future<void> remember(BookmarkVisualIndexRecord record) async {
    records.add(record);
  }
}
