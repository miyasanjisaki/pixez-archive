import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/network/api_client.dart';

class _PopularPreviewCall {
  _PopularPreviewCall({
    required this.searchTarget,
    required this.searchAiType,
    required this.startDate,
    required this.endDate,
  });

  final String searchTarget;
  final int? searchAiType;
  final DateTime? startDate;
  final DateTime? endDate;
  final completer = Completer<Response>();
}

class _FakePopularPreviewApiClient extends ApiClient {
  final calls = <_PopularPreviewCall>[];

  @override
  Future<Response> getPopularPreview(
    String keyword, {
    String searchTarget = 'partial_match_for_tags',
    int? searchAiType,
    DateTime? startDate,
    DateTime? endDate,
  }) {
    final call = _PopularPreviewCall(
      searchTarget: searchTarget,
      searchAiType: searchAiType,
      startDate: startDate,
      endDate: endDate,
    );
    calls.add(call);
    return call.completer.future;
  }
}

Response _response(int id) => Response(
  data: <String, dynamic>{
    'illusts': <Map<String, dynamic>>[
      <String, dynamic>{'id': id, 'title': 'illust $id'},
    ],
    'next_url': 'must-not-survive',
  },
  requestOptions: RequestOptions(path: '/popular-preview/$id'),
  statusCode: 200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('starts all official preview windows concurrently', () async {
    final client = _FakePopularPreviewApiClient();
    final future = client.getExpandedPopularPreview(
      'test tag',
      searchTarget: 'exact_match_for_tags',
      searchAiType: 1,
      now: DateTime(2026, 8, 15),
    );

    expect(client.calls, hasLength(5));
    expect(client.calls.map((call) => call.searchTarget).toSet(), {
      'exact_match_for_tags',
    });
    expect(client.calls.map((call) => call.searchAiType).toSet(), {1});
    expect(client.calls.first.startDate, isNull);
    expect(client.calls.first.endDate, isNull);
    expect(client.calls[1].startDate, DateTime.utc(2026, 7, 17));
    expect(client.calls[4].startDate, DateTime.utc(2007, 9, 1));

    for (var index = 0; index < client.calls.length; index++) {
      client.calls[index].completer.complete(_response(index + 1));
    }

    final response = await future;
    final data = response.data as Map<String, dynamic>;
    expect((data['illusts'] as List).map((item) => item['id']), [
      1,
      2,
      3,
      4,
      5,
    ]);
    expect(data['next_url'], isNull);
  });

  test('keeps successful windows when one request fails', () async {
    final client = _FakePopularPreviewApiClient();
    final future = client.getExpandedPopularPreview(
      'test tag',
      now: DateTime(2026, 8, 15),
    );

    for (var index = 0; index < client.calls.length; index++) {
      if (index == 2) {
        client.calls[index].completer.completeError(StateError('offline'));
      } else {
        client.calls[index].completer.complete(_response(index + 1));
      }
    }

    final response = await future;
    final data = response.data as Map<String, dynamic>;
    final metadata = data['popular_preview_merge'] as Map<String, dynamic>;
    expect((data['illusts'] as List).map((item) => item['id']), [1, 2, 4, 5]);
    expect(metadata['successful_count'], 4);
    expect(metadata['failed_count'], 1);
  });

  test('rethrows the first window error when every request fails', () async {
    final client = _FakePopularPreviewApiClient();
    final firstError = StateError('overall failed');
    final future = client.getExpandedPopularPreview(
      'test tag',
      now: DateTime(2026, 8, 15),
    );

    for (var index = 0; index < client.calls.length; index++) {
      client.calls[index].completer.completeError(
        index == 0 ? firstError : StateError('window $index failed'),
      );
    }

    await expectLater(future, throwsA(same(firstError)));
  });
}
