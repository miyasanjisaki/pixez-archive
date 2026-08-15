import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/popular_preview_merge.dart';

Map<String, dynamic> _response(Iterable<Object> ids) => <String, dynamic>{
  'illusts': [
    for (final id in ids) <String, dynamic>{'id': id, 'title': 'illust $id'},
  ],
  'next_url': 'must-not-survive',
};

void main() {
  test('uses a bounded set of official preview windows', () {
    expect(expandedPopularPreviewWindowOrder.map((window) => window.key), [
      'overall',
      'last_30_days',
      'days_31_to_180',
      'days_181_to_365',
      'days_366_plus',
    ]);
  });

  test('date windows are adjacent and cover the Pixiv archive', () {
    final windows = buildExpandedPopularPreviewWindows(
      DateTime(2026, 8, 15, 23, 59),
    );

    expect(windows.first.startDate, isNull);
    expect(windows.first.endDate, isNull);
    expect(windows[1].startDate, DateTime.utc(2026, 7, 17));
    expect(windows[1].endDate, DateTime.utc(2026, 8, 15));
    expect(windows[2].startDate, DateTime.utc(2026, 2, 17));
    expect(windows[2].endDate, DateTime.utc(2026, 7, 16));
    expect(windows[3].startDate, DateTime.utc(2025, 8, 16));
    expect(windows[3].endDate, DateTime.utc(2026, 2, 16));
    expect(windows[4].startDate, DateTime.utc(2007, 9, 1));
    expect(windows[4].endDate, DateTime.utc(2025, 8, 15));
  });

  test('uses canonical window order and retains the first duplicate', () {
    final result = mergePopularPreviewResponses([
      PopularPreviewWindowResult.success(
        popularPreviewDays31To180Window,
        _response([2, 4]),
      ),
      PopularPreviewWindowResult.success(
        popularPreviewLast30DaysWindow,
        _response([2, 3]),
      ),
      PopularPreviewWindowResult.success(
        popularPreviewOverallWindow,
        _response([1, 2]),
      ),
    ]);

    expect(result.illusts.map((illust) => illust['id']), [1, 2, 3, 4]);
    expect(result.rawCount, 6);
    expect(result.uniqueCount, 4);
    expect(result.windowSummaries.map((summary) => summary.window.key), [
      'overall',
      'last_30_days',
      'days_31_to_180',
    ]);
    expect(result.windowSummaries[1].duplicateCount, 1);
    expect(result.windowSummaries[2].duplicateCount, 1);
  });

  test('keeps all 150 unique candidates returned by five previews', () {
    final results = <PopularPreviewWindowResult>[];
    for (
      var index = 0;
      index < expandedPopularPreviewWindowOrder.length;
      index++
    ) {
      results.add(
        PopularPreviewWindowResult.success(
          expandedPopularPreviewWindowOrder[index],
          _response(List.generate(30, (item) => index * 30 + item + 1)),
        ),
      );
    }

    final result = mergePopularPreviewResponses(results);

    expect(result.rawCount, 150);
    expect(result.uniqueCount, 150);
    expect(result.illusts.first['id'], 1);
    expect(result.illusts.last['id'], 150);
  });

  test('deduplicates equivalent numeric IDs and keeps ID-less records', () {
    final result = mergePopularPreviewResponses([
      PopularPreviewWindowResult.success(
        popularPreviewOverallWindow,
        <String, dynamic>{
          'illusts': <Map<String, dynamic>>[
            <String, dynamic>{'id': 7, 'source': 'first'},
            <String, dynamic>{'title': 'without id 1'},
          ],
        },
      ),
      PopularPreviewWindowResult.success(
        popularPreviewLast30DaysWindow,
        <String, dynamic>{
          'illusts': <Map<String, dynamic>>[
            <String, dynamic>{'id': 7.0, 'source': 'duplicate'},
            <String, dynamic>{'id': '7', 'source': 'string duplicate'},
            <String, dynamic>{'title': 'without id 2'},
          ],
        },
      ),
    ]);

    expect(result.illusts, hasLength(3));
    expect(result.illusts.first['source'], 'first');
    expect(
      result.illusts.where((illust) => illust['id'] == null),
      hasLength(2),
    );
  });

  test('reports partial failures without discarding successful windows', () {
    final result = mergePopularPreviewResponses([
      PopularPreviewWindowResult.success(
        popularPreviewOverallWindow,
        _response([10, 11]),
      ),
      PopularPreviewWindowResult.failure(
        popularPreviewLast30DaysWindow,
        StateError('offline'),
      ),
      PopularPreviewWindowResult.success(
        popularPreviewDays31To180Window,
        _response([12]),
      ),
    ]);
    final responseData = result.toResponseData();
    final metadata =
        responseData['popular_preview_merge'] as Map<String, dynamic>;

    expect(result.successfulWindowCount, 2);
    expect(result.failedWindowCount, 1);
    expect(responseData['next_url'], isNull);
    expect(metadata['complete_global_ranking'], isFalse);
    expect(metadata['raw_count'], 3);
    expect(metadata['unique_count'], 3);
    expect(metadata['failed_count'], 1);
    expect((metadata['windows'] as List)[1], containsPair('succeeded', false));
    expect(
      (metadata['windows'] as List)[1],
      containsPair('error_type', 'StateError'),
    );
  });

  test('treats malformed successful payload as a failed window', () {
    final result = mergePopularPreviewResponses([
      PopularPreviewWindowResult.success(
        popularPreviewOverallWindow,
        <String, dynamic>{'illusts': 'not a list'},
      ),
    ]);

    expect(result.successfulWindowCount, 0);
    expect(result.failedWindowCount, 1);
    expect(result.rawCount, 0);
    expect(result.windowSummaries.single.errorType, 'FormatException');
  });
}
