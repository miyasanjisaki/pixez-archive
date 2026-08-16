import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pixez/network/external_search_transport.dart';
import 'package:pixez/network/network_mode.dart';

class _TrackingAdapter implements HttpClientAdapter {
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw UnimplementedError();
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

class _AbortObservingClient extends http.BaseClient {
  final Completer<http.BaseRequest> requestSeen = Completer<http.BaseRequest>();
  final Completer<void> abortObserved = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestSeen.complete(request);
    final abortable = request as http.Abortable;
    final abortTrigger = abortable.abortTrigger;
    if (abortTrigger == null) {
      throw StateError('Expected a non-null abort trigger');
    }
    await abortTrigger;
    abortObserved.complete();
    throw http.RequestAbortedException(request.url);
  }
}

class _RecordingClient extends http.BaseClient {
  http.BaseRequest? request;
  Uint8List? body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request;
    body = Uint8List.fromList(await request.finalize().toBytes());
    return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
  }
}

void main() {
  test('Dio cancellation aborts the package:http streamed request', () async {
    final client = _AbortObservingClient();
    final adapter = CancelAwareConversionLayerAdapter(client);
    addTearDown(adapter.close);
    final cancelled = Completer<void>();
    final options = RequestOptions(
      path: '/search',
      baseUrl: 'https://example.test',
      method: 'POST',
    );

    final pending = adapter.fetch(
      options,
      Stream<Uint8List>.value(Uint8List.fromList(const <int>[1, 2, 3])),
      cancelled.future,
    );
    final request = await client.requestSeen.future;
    expect(request, isA<http.AbortableStreamedRequest>());
    expect(client.abortObserved.isCompleted, isFalse);

    cancelled.complete();
    await expectLater(
      pending,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(client.abortObserved.isCompleted, isTrue);
  });

  test('preserves multipart bytes and request headers', () async {
    final client = _RecordingClient();
    final adapter = CancelAwareConversionLayerAdapter(client);
    addTearDown(adapter.close);
    const boundary = 'pixez-test-boundary';
    final bytes = Uint8List.fromList(const <int>[0, 1, 2, 3, 254, 255]);
    final options = RequestOptions(
      path: '/search',
      baseUrl: 'https://example.test',
      method: 'POST',
      headers: const <String, Object>{
        'Content-Type': 'multipart/form-data; boundary=$boundary',
        'Content-Length': '6',
        'X-PixEz-Test': 'preserved',
      },
    );

    final response = await adapter.fetch(
      options,
      Stream<Uint8List>.value(bytes),
      null,
    );

    expect(response.statusCode, 200);
    expect(client.body, bytes);
    expect(
      client.request?.headers['content-type'],
      'multipart/form-data; boundary=$boundary',
    );
    expect(client.request?.headers['content-length'], '6');
    expect(client.request?.headers['x-pixez-test'], 'preserved');
  });

  test('reuses a mode client and rebuilds after the mode changes', () async {
    var mode = NetworkMode.standard;
    final adapters = <_TrackingAdapter>[];
    final requestedModes = <NetworkMode>[];
    final owner = ExternalSearchDioClient(
      baseUrl: 'https://example.test',
      networkModeProvider: () => mode,
      factory:
          ({required String baseUrl, required NetworkMode networkMode}) async {
            requestedModes.add(networkMode);
            final adapter = _TrackingAdapter();
            adapters.add(adapter);
            return Dio(BaseOptions(baseUrl: baseUrl))
              ..httpClientAdapter = adapter;
          },
    );
    addTearDown(owner.close);

    final first = await owner.run((client) async => client);
    expect(await owner.run((client) async => client), same(first));
    expect(requestedModes, [NetworkMode.standard]);

    mode = NetworkMode.ech;
    final second = await owner.run((client) async => client);
    expect(second, isNot(same(first)));
    expect(adapters.first.closed, isTrue);
    expect(requestedModes, [NetworkMode.standard, NetworkMode.ech]);

    owner.close();
    expect(adapters.last.closed, isTrue);
  });

  test('injected Dio remains the test path regardless of mode', () async {
    var mode = NetworkMode.standard;
    var factoryCalls = 0;
    final injected = Dio();
    final owner = ExternalSearchDioClient(
      baseUrl: 'https://example.test',
      networkModeProvider: () => mode,
      injectedDio: injected,
      factory:
          ({required String baseUrl, required NetworkMode networkMode}) async {
            factoryCalls++;
            return Dio(BaseOptions(baseUrl: baseUrl));
          },
    );
    addTearDown(owner.close);

    expect(await owner.run((client) async => client), same(injected));
    mode = NetworkMode.compat;
    expect(await owner.run((client) async => client), same(injected));
    expect(factoryCalls, 0);
  });

  test('mode changes do not close an active request transport', () async {
    var mode = NetworkMode.standard;
    final adapters = <_TrackingAdapter>[];
    final requestStarted = Completer<Dio>();
    final releaseRequest = Completer<void>();
    final owner = ExternalSearchDioClient(
      baseUrl: 'https://example.test',
      networkModeProvider: () => mode,
      factory:
          ({required String baseUrl, required NetworkMode networkMode}) async {
            final adapter = _TrackingAdapter();
            adapters.add(adapter);
            return Dio(BaseOptions(baseUrl: baseUrl))
              ..httpClientAdapter = adapter;
          },
    );
    addTearDown(owner.close);

    final firstRequest = owner.run<void>((client) async {
      requestStarted.complete(client);
      await releaseRequest.future;
    });
    await requestStarted.future;

    mode = NetworkMode.ech;
    await owner.run<void>((_) async {});
    expect(adapters, hasLength(2));
    expect(adapters.first.closed, isFalse);

    releaseRequest.complete();
    await firstRequest;
    expect(adapters.first.closed, isTrue);
  });

  test('client returned after close is disposed and request fails', () async {
    final creation = Completer<Dio>();
    final adapter = _TrackingAdapter();
    final owner = ExternalSearchDioClient(
      baseUrl: 'https://example.test',
      networkModeProvider: () => NetworkMode.standard,
      factory: ({required String baseUrl, required NetworkMode networkMode}) =>
          creation.future,
    );

    final pending = owner.run<void>((_) async {});
    owner.close();
    creation.complete(
      Dio(BaseOptions(baseUrl: 'https://example.test'))
        ..httpClientAdapter = adapter,
    );

    await expectLater(pending, throwsA(isA<StateError>()));
    expect(adapter.closed, isTrue);
  });
}
