import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/models/novel_viewer_persist.dart';

void main() {
  test(
    'stores normalized reading progress alongside the legacy pixel offset',
    () {
      final position = NovelViewerPersist(
        novelId: 42,
        offset: 1200,
        progress: 0.4,
      );

      expect(position.toJson(), {
        'id': null,
        'novel_id': 42,
        'offset': 1200.0,
        'progress': 0.4,
      });
    },
  );

  test('opens legacy rows that do not contain normalized progress', () {
    final position = NovelViewerPersist.fromJson({
      'id': 1,
      'novel_id': 42,
      'offset': 1200.0,
    });

    expect(position.offset, 1200);
    expect(position.progress, isNull);
  });
}
