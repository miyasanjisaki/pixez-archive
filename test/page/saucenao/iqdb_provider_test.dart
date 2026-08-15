import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/page/saucenao/iqdb_provider.dart';
import 'package:pixez/utils/reverse_image_search.dart';

class _PendingHttpClientAdapter implements HttpClientAdapter {
  final Completer<void> _started = Completer<void>();

  Future<void> get started => _started.future;

  Future<void>? cancelFutureSeen;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    cancelFutureSeen = cancelFuture;
    if (!_started.isCompleted) _started.complete();
    return Completer<ResponseBody>().future;
  }

  @override
  void close({bool force = false}) {}
}

ReverseImageQuery _query() => ReverseImageQuery(
  bytes: Uint8List.fromList(const <int>[0xff, 0xd8, 0xff, 0xd9]),
  extension: 'jpg',
  probe: ReverseImageProbeKind.full,
);

void main() {
  test('reports the provider-owned total deadline as timeout', () async {
    final adapter = _PendingHttpClientAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://safe.iqdb.org'))
      ..httpClientAdapter = adapter;
    final provider = IqdbSearchProvider(
      dio: dio,
      totalTimeout: const Duration(milliseconds: 40),
    );
    addTearDown(provider.close);
    final token = CancelToken();

    final pending = provider.searchWithCancel(_query(), cancelToken: token);
    await adapter.started.timeout(const Duration(seconds: 1));
    final response = await pending.timeout(const Duration(seconds: 1));

    expect(adapter.cancelFutureSeen, isNotNull);
    expect(token.isCancelled, isTrue);
    expect(response.serviceMessage, startsWith('IQDB timed out after'));
  });

  test('reports earlier caller cancellation as cancellation', () async {
    final adapter = _PendingHttpClientAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://safe.iqdb.org'))
      ..httpClientAdapter = adapter;
    final provider = IqdbSearchProvider(
      dio: dio,
      totalTimeout: const Duration(seconds: 2),
    );
    addTearDown(provider.close);
    final token = CancelToken();

    final pending = provider.searchWithCancel(_query(), cancelToken: token);
    await adapter.started.timeout(const Duration(seconds: 1));
    token.cancel('user');
    final response = await pending.timeout(const Duration(seconds: 1));

    expect(response.serviceMessage, 'IQDB search cancelled');
  });
}
