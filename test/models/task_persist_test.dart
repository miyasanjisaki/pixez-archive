import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/models/task_persist.dart';

void main() {
  test('TaskPersist serializes preview metadata used after restart', () {
    final task = TaskPersist(
      userName: 'artist',
      title: 'title',
      url: 'https://example.test/original.jpg',
      userId: 1,
      illustId: 2,
      fileName: '2_p0.jpg',
      medium: 'https://example.test/preview.jpg',
      status: 0,
    );

    expect(task.toJson()[columnMedium], task.medium);
  });
}
