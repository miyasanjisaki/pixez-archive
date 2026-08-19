import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/network/external_search_transport.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:pixez/page/saucenao/sauce_store.dart';
import 'package:pixez/utils/saucenao_result_parser.dart';
import 'package:rhttp/rhttp.dart' as r;

class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.statusCode, {this.body = 'provider response'});

  final int statusCode;
  final String body;
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    return ResponseBody.fromString(body, statusCode);
  }

  @override
  void close({bool force = false}) {}
}

class _PendingAdapter implements HttpClientAdapter {
  int requestCount = 0;
  Future<void>? cancelFutureSeen;
  final Completer<void> started = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requestCount++;
    cancelFutureSeen = cancelFuture;
    if (!started.isCompleted) started.complete();
    return Completer<ResponseBody>().future;
  }

  @override
  void close({bool force = false}) {}
}

class _RecordingAttemptAdapter implements HttpClientAdapter {
  _RecordingAttemptAdapter({required this.failCertificate});

  final bool failCertificate;
  final List<Uint8List> bodies = <Uint8List>[];
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    final builder = BytesBuilder(copy: false);
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
    }
    bodies.add(builder.takeBytes());
    if (failCertificate) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: r.RhttpInvalidCertificateException(
          request: r.HttpRequest(url: options.uri.toString()),
          message: 'test certificate rejection',
        ),
      );
    }
    return ResponseBody.fromString('<html></html>', 200);
  }

  @override
  void close({bool force = false}) {}
}

bool _containsBytes(Uint8List body, List<int> expected) {
  if (expected.isEmpty) return true;
  for (var start = 0; start + expected.length <= body.length; start++) {
    var matches = true;
    for (var offset = 0; offset < expected.length; offset++) {
      if (body[start + offset] != expected[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

Future<Uint8List> _readMultipartFile(MultipartFile file) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.finalize()) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void main() {
  test(
    'each SauceNAO attempt gets an equivalent fresh multipart body',
    () async {
      final bytes = Uint8List.fromList(const <int>[0, 1, 2, 3, 254, 255]);

      final first = buildSauceNaoSearchFormData(bytes: bytes, extension: 'png');
      final second = buildSauceNaoSearchFormData(
        bytes: bytes,
        extension: 'png',
      );

      expect(second, isNot(same(first)));
      expect(Map<String, String>.fromEntries(first.fields), isEmpty);
      expect(
        Map<String, String>.fromEntries(second.fields),
        Map<String, String>.fromEntries(first.fields),
      );

      final firstFile = first.files.single;
      final secondFile = second.files.single;
      expect(firstFile.key, 'file');
      expect(secondFile.key, 'file');
      expect(secondFile.value, isNot(same(firstFile.value)));
      expect(firstFile.value.filename, 'pixez_reverse_search.png');
      expect(secondFile.value.filename, firstFile.value.filename);
      expect(await _readMultipartFile(firstFile.value), bytes);
      expect(await _readMultipartFile(secondFile.value), bytes);
    },
  );

  test('TLS fallback rebuilds equivalent SauceNAO multipart uploads', () async {
    final channels = <ExternalTlsTrustChannel>[];
    final adapters = <ExternalTlsTrustChannel, _RecordingAttemptAdapter>{};
    final client = ExternalSearchDioClient(
      baseUrl: 'https://saucenao.com',
      networkModeProvider: () => NetworkMode.standard,
      trustPlan: const ExternalTlsHostPlan(
        primary: ExternalTlsTrustChannel.webpki,
        invalidCertificateFallbacks: <ExternalTlsTrustChannel>[
          ExternalTlsTrustChannel.androidSecurityContext,
        ],
      ),
      factory:
          ({
            required String baseUrl,
            required NetworkMode networkMode,
            required ExternalTlsTrustChannel trustChannel,
          }) async {
            channels.add(trustChannel);
            final adapter = _RecordingAttemptAdapter(
              failCertificate: trustChannel == ExternalTlsTrustChannel.webpki,
            );
            adapters[trustChannel] = adapter;
            return Dio(BaseOptions(baseUrl: baseUrl, followRedirects: false))
              ..httpClientAdapter = adapter;
          },
    );
    addTearDown(client.close);
    final fileBytes = Uint8List.fromList(const <int>[11, 22, 33, 44, 55]);

    final result = await executeSauceNaoSearchRequest(
      client: client,
      bytes: fileBytes,
      extension: 'png',
      cancelToken: CancelToken(),
    );

    expect(result.exactMatches, isEmpty);
    expect(channels, const <ExternalTlsTrustChannel>[
      ExternalTlsTrustChannel.webpki,
      ExternalTlsTrustChannel.androidSecurityContext,
    ]);
    for (final channel in channels) {
      final adapter = adapters[channel]!;
      expect(adapter.requestCount, 1, reason: channel.name);
      expect(adapter.bodies, hasLength(1), reason: channel.name);
      final body = adapter.bodies.single;
      expect(_containsBytes(body, 'name="dbs[]"'.codeUnits), isFalse);
      expect(_containsBytes(body, 'name="db"'.codeUnits), isFalse);
      expect(
        _containsBytes(body, 'filename="pixez_reverse_search.png"'.codeUnits),
        isTrue,
        reason: channel.name,
      );
      expect(_containsBytes(body, fileBytes), isTrue, reason: channel.name);
    }
  });

  test('default request does not override SauceNAO database selection', () {
    final form = buildSauceNaoSearchFormData(
      bytes: Uint8List.fromList(const <int>[1, 2, 3]),
      extension: 'jpg',
    );

    expect(Map<String, String>.fromEntries(form.fields), isEmpty);
    expect(form.files.single.value.filename, 'pixez_reverse_search.jpg');
  });

  for (final statusCode in const <int>[403, 429]) {
    test('HTTP $statusCode is returned after one SauceNAO upload', () async {
      final channels = <ExternalTlsTrustChannel>[];
      final adapters = <ExternalTlsTrustChannel, _StatusAdapter>{};
      final client = ExternalSearchDioClient(
        baseUrl: 'https://saucenao.com',
        networkModeProvider: () => NetworkMode.standard,
        trustPlan: const ExternalTlsHostPlan(
          primary: ExternalTlsTrustChannel.webpki,
          invalidCertificateFallbacks: <ExternalTlsTrustChannel>[
            ExternalTlsTrustChannel.androidSecurityContext,
          ],
        ),
        factory:
            ({
              required String baseUrl,
              required NetworkMode networkMode,
              required ExternalTlsTrustChannel trustChannel,
            }) async {
              channels.add(trustChannel);
              final adapter = _StatusAdapter(statusCode);
              adapters[trustChannel] = adapter;
              return Dio(BaseOptions(baseUrl: baseUrl, followRedirects: false))
                ..httpClientAdapter = adapter;
            },
      );
      addTearDown(client.close);

      await expectLater(
        executeSauceNaoSearchRequest(
          client: client,
          bytes: Uint8List.fromList(const <int>[0xff, 0xd8, 0xff, 0xd9]),
          extension: 'jpg',
          cancelToken: CancelToken(),
        ),
        throwsA(
          isA<DioException>().having(
            (error) => error.response?.statusCode,
            'status code',
            statusCode,
          ),
        ),
      );
      expect(channels, const <ExternalTlsTrustChannel>[
        ExternalTlsTrustChannel.webpki,
      ]);
      expect(adapters.values.single.requestCount, 1);
    });
  }

  test('one deadline cancels only the active SauceNAO transport', () async {
    final adapter = _PendingAdapter();
    final dio = Dio(
      BaseOptions(baseUrl: 'https://saucenao.com', followRedirects: false),
    )..httpClientAdapter = adapter;
    final client = ExternalSearchDioClient(
      baseUrl: 'https://saucenao.com',
      networkModeProvider: () => NetworkMode.standard,
      injectedDio: dio,
    );
    addTearDown(client.close);
    final cancelToken = CancelToken();

    await expectLater(
      executeSauceNaoSearchRequest(
        client: client,
        bytes: Uint8List.fromList(const <int>[0xff, 0xd8, 0xff, 0xd9]),
        extension: 'jpg',
        cancelToken: cancelToken,
        requestBudget: const Duration(milliseconds: 30),
      ),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
    expect(
      cancelToken.isCancelled,
      isFalse,
      reason: 'a provider timeout must not cancel the whole search session',
    );
    expect(adapter.cancelFutureSeen, isNotNull);
    await expectLater(
      adapter.cancelFutureSeen!.timeout(const Duration(seconds: 1)),
      completes,
      reason: 'the provider-owned request token must abort the active upload',
    );
    expect(adapter.requestCount, 1);
  });

  test(
    'caller cancellation still aborts the active SauceNAO transport',
    () async {
      final adapter = _PendingAdapter();
      final dio = Dio(
        BaseOptions(baseUrl: 'https://saucenao.com', followRedirects: false),
      )..httpClientAdapter = adapter;
      final client = ExternalSearchDioClient(
        baseUrl: 'https://saucenao.com',
        networkModeProvider: () => NetworkMode.standard,
        injectedDio: dio,
      );
      addTearDown(client.close);
      final cancelToken = CancelToken();

      final pending = executeSauceNaoSearchRequest(
        client: client,
        bytes: Uint8List.fromList(const <int>[0xff, 0xd8, 0xff, 0xd9]),
        extension: 'jpg',
        cancelToken: cancelToken,
        requestBudget: const Duration(seconds: 2),
      );
      await adapter.started.future.timeout(const Duration(seconds: 1));
      cancelToken.cancel('user');

      await expectLater(
        pending.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(cancelToken.isCancelled, isTrue);
      await expectLater(
        adapter.cancelFutureSeen!.timeout(const Duration(seconds: 1)),
        completes,
      );
      expect(adapter.requestCount, 1);
    },
  );

  test('SauceNAO parser failure does not replay the upload', () async {
    final adapter = _StatusAdapter(
      200,
      body: '<form>CAPTCHA verification required</form>',
    );
    final dio = Dio(
      BaseOptions(baseUrl: 'https://saucenao.com', followRedirects: false),
    )..httpClientAdapter = adapter;
    final client = ExternalSearchDioClient(
      baseUrl: 'https://saucenao.com',
      networkModeProvider: () => NetworkMode.standard,
      injectedDio: dio,
    );
    addTearDown(client.close);

    await expectLater(
      executeSauceNaoSearchRequest(
        client: client,
        bytes: Uint8List.fromList(const <int>[0xff, 0xd8, 0xff, 0xd9]),
        extension: 'jpg',
        cancelToken: CancelToken(),
      ),
      throwsA(isA<SauceNaoResponseException>()),
    );
    expect(adapter.requestCount, 1);
  });
}
