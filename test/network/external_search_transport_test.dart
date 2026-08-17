import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pixez/network/external_search_transport.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:rhttp/rhttp.dart' as r;

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

class _SuccessAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
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
  _RecordingClient({this.statusCode = 200});

  final int statusCode;
  http.BaseRequest? request;
  Uint8List? body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request;
    body = Uint8List.fromList(await request.finalize().toBytes());
    return http.StreamedResponse(const Stream<List<int>>.empty(), statusCode);
  }
}

DioException _invalidCertificateError({int? statusCode}) {
  final requestOptions = RequestOptions(path: '/search');
  final request = r.HttpRequest(url: 'https://saucenao.com/search.php');
  final cause = r.RhttpInvalidCertificateException(
    request: request,
    message: 'certificate rejected',
  );
  return DioException(
    requestOptions: requestOptions,
    type: DioExceptionType.connectionError,
    error: r.RhttpWrappedClientException(
      'redacted',
      Uri.parse('https://saucenao.com/search.php'),
      cause,
    ),
    response: statusCode == null
        ? null
        : Response<void>(
            requestOptions: requestOptions,
            statusCode: statusCode,
          ),
  );
}

const _androidFallbackPlan = ExternalTlsHostPlan(
  primary: ExternalTlsTrustChannel.webpki,
  invalidCertificateFallbacks: <ExternalTlsTrustChannel>[
    ExternalTlsTrustChannel.androidSecurityContext,
  ],
);

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

  test(
    'bridge preserves a no-redirect request and returns redirect status',
    () async {
      final client = _RecordingClient(statusCode: 302);
      final adapter = CancelAwareConversionLayerAdapter(client);
      addTearDown(adapter.close);
      final options = RequestOptions(
        path: '/search',
        baseUrl: 'https://example.test',
        method: 'GET',
        followRedirects: false,
      );

      final response = await adapter.fetch(options, null, null);

      expect(response.statusCode, 302);
      expect(client.request?.followRedirects, isFalse);
    },
  );

  test(
    'typed certificate failure retries once and rebuilds the attempt',
    () async {
      final createdChannels = <ExternalTlsTrustChannel>[];
      final clients = <ExternalTlsTrustChannel, Dio>{};
      final owner = ExternalSearchDioClient(
        baseUrl: 'https://saucenao.com',
        networkModeProvider: () => NetworkMode.standard,
        trustPlan: _androidFallbackPlan,
        factory:
            ({
              required String baseUrl,
              required NetworkMode networkMode,
              required ExternalTlsTrustChannel trustChannel,
            }) async {
              createdChannels.add(trustChannel);
              final client = Dio(BaseOptions(baseUrl: baseUrl))
                ..httpClientAdapter = _TrackingAdapter();
              clients[trustChannel] = client;
              return client;
            },
      );
      addTearDown(owner.close);
      final requestBodies = <Object>[];

      final result = await owner.runWithTlsFallback<String>((dio) async {
        requestBodies.add(Object());
        if (requestBodies.length == 1) throw _invalidCertificateError();
        expect(
          dio,
          same(clients[ExternalTlsTrustChannel.androidSecurityContext]),
        );
        return 'matched';
      });

      expect(result, 'matched');
      expect(requestBodies, hasLength(2));
      expect(identical(requestBodies[0], requestBodies[1]), isFalse);
      expect(createdChannels, <ExternalTlsTrustChannel>[
        ExternalTlsTrustChannel.webpki,
        ExternalTlsTrustChannel.androidSecurityContext,
      ]);
      expect(
        await owner.run((dio) async => dio),
        same(clients[ExternalTlsTrustChannel.webpki]),
        reason:
            'the primary and fallback channels must have separate cache keys',
      );
      expect(createdChannels, hasLength(2));
    },
  );

  test(
    'generic TLS text, HTTP, cancellation and timeout never retry',
    () async {
      final request = r.HttpRequest(url: 'https://saucenao.com/search.php');
      final requestOptions = RequestOptions(path: '/search');
      final cases = <String, DioException>{
        'TLS text': DioException(
          requestOptions: requestOptions,
          type: DioExceptionType.connectionError,
          error: r.RhttpWrappedClientException(
            'redacted',
            Uri.parse('https://saucenao.com/search.php'),
            r.RhttpConnectionException(
              request,
              'TLS handshake and certificate verification failed',
            ),
          ),
        ),
        'HTTP 429': _invalidCertificateError(statusCode: 429),
        'cancel': DioException(
          requestOptions: requestOptions,
          type: DioExceptionType.cancel,
          error: _invalidCertificateError().error,
        ),
        'timeout': DioException(
          requestOptions: requestOptions,
          type: DioExceptionType.receiveTimeout,
          error: _invalidCertificateError().error,
        ),
        'transform timeout': DioException(
          requestOptions: requestOptions,
          type: DioExceptionType.transformTimeout,
          error: _invalidCertificateError().error,
        ),
      };

      for (final entry in cases.entries) {
        final createdChannels = <ExternalTlsTrustChannel>[];
        var attempts = 0;
        final owner = ExternalSearchDioClient(
          baseUrl: 'https://saucenao.com',
          networkModeProvider: () => NetworkMode.standard,
          trustPlan: _androidFallbackPlan,
          factory:
              ({
                required String baseUrl,
                required NetworkMode networkMode,
                required ExternalTlsTrustChannel trustChannel,
              }) async {
                createdChannels.add(trustChannel);
                return Dio(BaseOptions(baseUrl: baseUrl));
              },
        );
        try {
          await expectLater(
            owner.runWithTlsFallback<void>((_) async {
              attempts++;
              throw entry.value;
            }),
            throwsA(same(entry.value)),
            reason: entry.key,
          );
          expect(attempts, 1, reason: entry.key);
          expect(createdChannels, <ExternalTlsTrustChannel>[
            ExternalTlsTrustChannel.webpki,
          ], reason: entry.key);
        } finally {
          owner.close();
        }
      }
    },
  );

  test('single-channel host plans never replay certificate failures', () async {
    for (final plan in <ExternalTlsHostPlan>[
      PixezNetworkSettings.externalTlsHostPlan(
        'unknown.example',
        isAndroid: true,
      ),
      PixezNetworkSettings.externalTlsHostPlan(
        'saucenao.com',
        isAndroid: false,
      ),
    ]) {
      var attempts = 0;
      final owner = ExternalSearchDioClient(
        baseUrl: 'https://unknown.example',
        networkModeProvider: () => NetworkMode.standard,
        trustPlan: plan,
        factory:
            ({
              required String baseUrl,
              required NetworkMode networkMode,
              required ExternalTlsTrustChannel trustChannel,
            }) async => Dio(BaseOptions(baseUrl: baseUrl)),
      );
      try {
        await expectLater(
          owner.runWithTlsFallback<void>((_) async {
            attempts++;
            throw _invalidCertificateError();
          }),
          throwsA(isA<DioException>()),
        );
        expect(attempts, 1);
      } finally {
        owner.close();
      }
    }
  });

  test('Dart IO fallback rejects every non-exact HTTPS origin', () {
    ExternalSearchDioClient build(String baseUrl) => ExternalSearchDioClient(
      baseUrl: baseUrl,
      networkModeProvider: () => NetworkMode.standard,
      trustPlan: _androidFallbackPlan,
    );

    for (final baseUrl in const <String>[
      'http://saucenao.com',
      'https://user@saucenao.com',
      'https://saucenao.com:444',
      'https://saucenao.com.evil.test',
      'https://saucenao.com/search.php',
      'https://saucenao.com/?db=999',
      'https://saucenao.com/#fragment',
    ]) {
      expect(() => build(baseUrl), throwsArgumentError, reason: baseUrl);
    }

    final exact = build('https://saucenao.com/');
    exact.close();
  });

  test('every provider request is confined to its configured origin', () async {
    final adapter = _SuccessAdapter();
    final injected = Dio(BaseOptions(baseUrl: 'https://saucenao.com'))
      ..httpClientAdapter = adapter;
    final owner = ExternalSearchDioClient(
      baseUrl: 'https://saucenao.com',
      networkModeProvider: () => NetworkMode.standard,
      injectedDio: injected,
    );
    addTearDown(owner.close);

    await owner.run((dio) => dio.get<void>('/search.php'));
    expect(adapter.requests, 1);

    await expectLater(
      owner.run((dio) => dio.get<void>('https://evil.example/search.php')),
      throwsA(
        isA<DioException>().having(
          (error) => error.error,
          'redacted origin rejection',
          isA<StateError>(),
        ),
      ),
    );
    expect(adapter.requests, 1, reason: 'off-origin request must not be sent');

    await expectLater(
      owner.run(
        (dio) => dio.get<void>(
          '/search.php',
          options: Options(followRedirects: true),
        ),
      ),
      throwsA(isA<DioException>()),
    );
    expect(
      adapter.requests,
      1,
      reason: 'redirect-enabled request must not send',
    );
  });

  test('reuses a mode client and rebuilds after the mode changes', () async {
    var mode = NetworkMode.standard;
    final adapters = <_TrackingAdapter>[];
    final requestedModes = <NetworkMode>[];
    final owner = ExternalSearchDioClient(
      baseUrl: 'https://example.test',
      networkModeProvider: () => mode,
      factory:
          ({
            required String baseUrl,
            required NetworkMode networkMode,
            required ExternalTlsTrustChannel trustChannel,
          }) async {
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
          ({
            required String baseUrl,
            required NetworkMode networkMode,
            required ExternalTlsTrustChannel trustChannel,
          }) async {
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
          ({
            required String baseUrl,
            required NetworkMode networkMode,
            required ExternalTlsTrustChannel trustChannel,
          }) async {
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

  test(
    'mode retirement respects active leases on both trust channels',
    () async {
      var mode = NetworkMode.standard;
      final adapters = <_TrackingAdapter>[];
      final primaryStarted = Completer<void>();
      final releasePrimary = Completer<void>();
      final fallbackStarted = Completer<void>();
      final releaseFallback = Completer<void>();
      final owner = ExternalSearchDioClient(
        baseUrl: 'https://saucenao.com',
        networkModeProvider: () => mode,
        trustPlan: _androidFallbackPlan,
        factory:
            ({
              required String baseUrl,
              required NetworkMode networkMode,
              required ExternalTlsTrustChannel trustChannel,
            }) async {
              final adapter = _TrackingAdapter();
              adapters.add(adapter);
              return Dio(BaseOptions(baseUrl: baseUrl))
                ..httpClientAdapter = adapter;
            },
      );
      addTearDown(owner.close);

      final primaryRequest = owner.run<void>((_) async {
        primaryStarted.complete();
        await releasePrimary.future;
      });
      await primaryStarted.future;

      var fallbackAttempts = 0;
      final fallbackRequest = owner.runWithTlsFallback<void>((_) async {
        fallbackAttempts++;
        if (fallbackAttempts == 1) throw _invalidCertificateError();
        fallbackStarted.complete();
        await releaseFallback.future;
      });
      await fallbackStarted.future;
      expect(adapters, hasLength(2));

      mode = NetworkMode.ech;
      await owner.run<void>((_) async {});
      expect(adapters, hasLength(3));
      expect(adapters[0].closed, isFalse);
      expect(adapters[1].closed, isFalse);

      releasePrimary.complete();
      await primaryRequest;
      expect(adapters[0].closed, isTrue);
      expect(adapters[1].closed, isFalse);

      releaseFallback.complete();
      await fallbackRequest;
      expect(adapters[1].closed, isTrue);
    },
  );

  test('client returned after close is disposed and request fails', () async {
    final creation = Completer<Dio>();
    final adapter = _TrackingAdapter();
    final owner = ExternalSearchDioClient(
      baseUrl: 'https://example.test',
      networkModeProvider: () => NetworkMode.standard,
      factory:
          ({
            required String baseUrl,
            required NetworkMode networkMode,
            required ExternalTlsTrustChannel trustChannel,
          }) => creation.future,
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
