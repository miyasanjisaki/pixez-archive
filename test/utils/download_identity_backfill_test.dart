import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/download_identity_backfill.dart';

CompletedDownloadBackfillReference _task({
  required int illustId,
  required String fileName,
  String? url,
}) => CompletedDownloadBackfillReference(
  sourceUrl:
      url ??
      'https://i.pximg.net/img-original/img/2026/01/01/00/00/00/${illustId}_p0.jpg',
  illustId: illustId,
  fileName: fileName,
);

void main() {
  group('planDownloadIdentityBackfill', () {
    test('accepts canonical Pixiv names without a task row', () {
      final plan = planDownloadIdentityBackfill(
        savedImages: const <SavedImageBackfillReference>[
          SavedImageBackfillReference(
            token: 'content://pixez/one',
            displayName: '140739814_p3.jpg',
            byteLength: 1024,
          ),
        ],
        completedDownloads: const <CompletedDownloadBackfillReference>[],
      );

      expect(plan.candidates, hasLength(1));
      expect(plan.candidates.single.illustId, 140739814);
      expect(plan.candidates.single.pageIndex, 3);
      expect(
        plan.candidates.single.evidence,
        DownloadIdentityBackfillEvidence.canonicalFileName,
      );
    });

    test('uses an exact matching completed legacy task for custom names', () {
      final plan = planDownloadIdentityBackfill(
        savedImages: const <SavedImageBackfillReference>[
          SavedImageBackfillReference(
            token: '/storage/emulated/0/Pictures/PixEz/legacy.jpg',
            displayName: 'legacy.jpg',
          ),
        ],
        completedDownloads: <CompletedDownloadBackfillReference>[
          _task(
            illustId: 140739814,
            fileName: 'legacy.jpg',
            url: 'https://i.pximg.net/img-original/x/140739814_p2.jpg',
          ),
        ],
      );

      expect(plan.candidates, hasLength(1));
      expect(plan.candidates.single.illustId, 140739814);
      expect(plan.candidates.single.pageIndex, 2);
      expect(
        plan.candidates.single.evidence,
        DownloadIdentityBackfillEvidence.completedDownloadTask,
      );
    });

    test('does not strip collision suffixes to guess a legacy task', () {
      final plan = planDownloadIdentityBackfill(
        savedImages: const <SavedImageBackfillReference>[
          SavedImageBackfillReference(
            token: '/storage/emulated/0/Pictures/PixEz/legacy (1).jpg',
            displayName: 'legacy (1).jpg',
          ),
        ],
        completedDownloads: <CompletedDownloadBackfillReference>[
          _task(illustId: 140739814, fileName: 'legacy.jpg'),
        ],
      );

      expect(plan.candidates, isEmpty);
      expect(plan.unidentifiedCount, 1);
    });

    test('rejects conflicting filename and task evidence', () {
      final plan = planDownloadIdentityBackfill(
        savedImages: const <SavedImageBackfillReference>[
          SavedImageBackfillReference(
            token: 'one',
            displayName: '140739814_p0.jpg',
          ),
        ],
        completedDownloads: <CompletedDownloadBackfillReference>[
          _task(illustId: 99999999, fileName: '140739814_p0.jpg'),
        ],
      );

      expect(plan.candidates, isEmpty);
      expect(plan.ambiguousCount, 1);
    });

    test('does not guess a random gallery filename without task evidence', () {
      final plan = planDownloadIdentityBackfill(
        savedImages: const <SavedImageBackfillReference>[
          SavedImageBackfillReference(
            token: 'content://gallery/random-copy',
            displayName: 'random-copy.jpg',
          ),
        ],
        completedDownloads: const <CompletedDownloadBackfillReference>[],
      );

      expect(plan.candidates, isEmpty);
      expect(plan.unidentifiedCount, 1);
    });

    test('rejects conflicting page evidence for the same work', () {
      final plan = planDownloadIdentityBackfill(
        savedImages: const <SavedImageBackfillReference>[
          SavedImageBackfillReference(
            token: 'content://pixez/page-conflict',
            displayName: '140739814_p0.jpg',
          ),
        ],
        completedDownloads: <CompletedDownloadBackfillReference>[
          _task(
            illustId: 140739814,
            fileName: '140739814_p0.jpg',
            url: 'https://i.pximg.net/img-original/x/140739814_p1.jpg',
          ),
        ],
      );

      expect(plan.candidates, isEmpty);
      expect(plan.ambiguousCount, 1);
    });

    test('is bounded and skips duplicate tokens and oversized files', () {
      final plan = planDownloadIdentityBackfill(
        savedImages: const <SavedImageBackfillReference>[
          SavedImageBackfillReference(
            token: 'one',
            displayName: '11111111_p0.jpg',
            byteLength: 100,
          ),
          SavedImageBackfillReference(
            token: 'one',
            displayName: '22222222_p0.jpg',
            byteLength: 100,
          ),
          SavedImageBackfillReference(
            token: 'large',
            displayName: '33333333_p0.jpg',
            byteLength: 1001,
          ),
          SavedImageBackfillReference(
            token: 'two',
            displayName: '44444444_p0.jpg',
            byteLength: 100,
          ),
        ],
        completedDownloads: const <CompletedDownloadBackfillReference>[],
        maximumCandidates: 1,
        maximumImageBytes: 1000,
      );

      expect(plan.candidates.single.illustId, 11111111);
      expect(plan.duplicateTokenCount, 1);
      expect(plan.oversizedCount, 1);
      expect(plan.truncated, isTrue);
    });

    test('reports when the native source scan was truncated', () {
      final plan = planDownloadIdentityBackfill(
        savedImages: const <SavedImageBackfillReference>[
          SavedImageBackfillReference(
            token: 'one',
            displayName: '11111111_p0.jpg',
          ),
        ],
        completedDownloads: const <CompletedDownloadBackfillReference>[],
        sourceTruncated: true,
      );

      expect(plan.truncated, isTrue);
    });
  });

  group('runDownloadIdentityBackfill', () {
    DownloadIdentityBackfillPlan twoItemPlan() => planDownloadIdentityBackfill(
      savedImages: const <SavedImageBackfillReference>[
        SavedImageBackfillReference(
          token: 'one',
          displayName: '11111111_p0.jpg',
        ),
        SavedImageBackfillReference(
          token: 'two',
          displayName: '22222222_p1.jpg',
        ),
      ],
      completedDownloads: const <CompletedDownloadBackfillReference>[],
    );

    test('indexes sequentially and reports progress', () async {
      final remembered = <int>[];
      final progress = <DownloadIdentityBackfillProgress>[];

      final summary = await runDownloadIdentityBackfill(
        plan: twoItemPlan(),
        readImage: (image) async => Uint8List.fromList(<int>[1, 2, 3]),
        computeFingerprints: (bytes) async => <String, String?>{
          'sha256': List<String>.filled(64, 'a').join(),
          'dhash': '0123456789abcdef',
        },
        rememberIdentity: (candidate, fingerprints) async {
          remembered.add(candidate.illustId);
          return true;
        },
        onProgress: progress.add,
      );

      expect(remembered, <int>[11111111, 22222222]);
      expect(summary.indexed, 2);
      expect(summary.failed, 0);
      expect(summary.cancelled, isFalse);
      expect(progress.last.processed, 2);
    });

    test('can be cancelled between files', () async {
      var readCount = 0;
      var cancel = false;
      final summary = await runDownloadIdentityBackfill(
        plan: twoItemPlan(),
        readImage: (image) async {
          readCount++;
          return Uint8List.fromList(<int>[1]);
        },
        computeFingerprints: (bytes) async => <String, String?>{
          'sha256': List<String>.filled(64, 'b').join(),
        },
        rememberIdentity: (candidate, fingerprints) async {
          cancel = true;
          return true;
        },
        shouldCancel: () => cancel,
      );

      expect(readCount, 1);
      expect(summary.indexed, 1);
      expect(summary.processed, 1);
      expect(summary.cancelled, isTrue);
    });

    test('aborts on caller-classified platform failures', () async {
      await expectLater(
        runDownloadIdentityBackfill(
          plan: twoItemPlan(),
          readImage: (image) => throw StateError('authorization lost'),
          computeFingerprints: (bytes) async => <String, String?>{},
          rememberIdentity: (candidate, fingerprints) async => true,
          abortOnError: (error) => error is StateError,
        ),
        throwsStateError,
      );
    });

    test('counts an identity conflict as skipped', () async {
      final summary = await runDownloadIdentityBackfill(
        plan: twoItemPlan(),
        readImage: (image) async => Uint8List.fromList(<int>[1]),
        computeFingerprints: (bytes) async => <String, String?>{
          'sha256': List<String>.filled(64, 'c').join(),
        },
        rememberIdentity: (candidate, fingerprints) async => false,
      );

      expect(summary.indexed, 0);
      expect(summary.skipped, 2);
      expect(summary.failed, 0);
    });
  });
}
