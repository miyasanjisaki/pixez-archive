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

  test('normalizes Android display names and finds completed old downloads', () {
    final failed = TaskPersist(
      id: 3,
      userName: 'artist',
      title: 'failed',
      url: 'https://example.test/failed.jpg',
      userId: 1,
      illustId: 11111111,
      fileName: '自定义名.jpg',
      status: 3,
    );
    final completed = TaskPersist(
      id: 4,
      userName: 'artist',
      title: 'completed',
      url: 'https://example.test/original.jpg',
      userId: 1,
      illustId: 22222222,
      fileName: '自定义名.jpg',
      status: 2,
    );

    expect(
      normalizeDownloadedImageName(
        'content://picker/item?displayName=%E8%87%AA%E5%AE%9A%E4%B9%89%E5%90%8D.jpg',
      ),
      '自定义名.jpg',
    );
    expect(
      findCompletedDownloadByName([
        failed,
        completed,
      ], r'C:\Pictures\自定义名 (1).JPG')?.illustId,
      22222222,
    );
  });

  test('does not guess when custom download names are ambiguous', () {
    TaskPersist completed(int id, int illustId) => TaskPersist(
      id: id,
      userName: 'artist',
      title: 'title',
      url: 'https://example.test/$id.jpg',
      userId: 1,
      illustId: illustId,
      fileName: 'same custom name.jpg',
      status: 2,
    );

    expect(
      findCompletedDownloadByName([
        completed(1, 11111111),
        completed(2, 22222222),
      ], 'same custom name.jpg'),
      isNull,
    );
  });
}
