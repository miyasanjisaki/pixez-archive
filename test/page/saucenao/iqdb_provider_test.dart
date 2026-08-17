import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/network/external_search_transport.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:pixez/page/saucenao/iqdb_provider.dart';
import 'package:pixez/utils/reverse_image_search.dart';
import 'package:rhttp/rhttp.dart' as r;

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

typedef _FetchHandler =
    Future<ResponseBody> Function(
      RequestOptions options,
      Uint8List body,
      Future<void>? cancelFuture,
    );

class _ScriptedHttpClientAdapter implements HttpClientAdapter {
  const _ScriptedHttpClientAdapter(this.handler);

  final _FetchHandler handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final builder = BytesBuilder(copy: false);
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
    }
    return handler(options, builder.takeBytes(), cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

class _CapturedRequest {
  const _CapturedRequest(this.options, this.body);

  final RequestOptions options;
  final Uint8List body;
}

ReverseImageQuery _query() => ReverseImageQuery(
  bytes: Uint8List.fromList(const <int>[0xff, 0xd8, 0xff, 0xd9]),
  extension: 'jpg',
  probe: ReverseImageProbeKind.full,
);

ExternalSearchDioClient _fallbackClient({
  required _FetchHandler handler,
  List<ExternalTlsTrustChannel>? channels,
}) {
  return ExternalSearchDioClient(
    baseUrl: 'https://safe.iqdb.org',
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
          channels?.add(trustChannel);
          return Dio(BaseOptions(baseUrl: baseUrl, followRedirects: false))
            ..httpClientAdapter = _ScriptedHttpClientAdapter(handler);
        },
  );
}

DioException _invalidCertificate(RequestOptions options) {
  final request = r.HttpRequest(url: options.uri.toString());
  final certificateError = r.RhttpInvalidCertificateException(
    request: request,
    message: 'InvalidCertificate(UnknownIssuer)',
  );
  return DioException(
    requestOptions: options,
    type: DioExceptionType.connectionError,
    error: r.RhttpWrappedClientException(
      'redacted certificate failure',
      options.uri,
      certificateError,
    ),
  );
}

String _normalizedMultipart(_CapturedRequest request) {
  final contentType =
      request.options.headers[Headers.contentTypeHeader]?.toString() ?? '';
  final match = RegExp(r'boundary=([^;]+)').firstMatch(contentType);
  expect(match, isNotNull, reason: 'Dio must encode a multipart boundary');
  final boundary = match!.group(1)!.replaceAll('"', '').trim();
  return latin1.decode(request.body).replaceAll(boundary, '<boundary>');
}

ResponseBody _okResponse() => ResponseBody.fromString('<html></html>', 200);

void main() {
  test(
    'rebuilds identical multipart data when typed certificate fallback succeeds',
    () async {
      final requests = <_CapturedRequest>[];
      final channels = <ExternalTlsTrustChannel>[];
      var attempt = 0;
      final client = _fallbackClient(
        channels: channels,
        handler: (options, body, _) async {
          requests.add(_CapturedRequest(options, body));
          attempt++;
          if (attempt == 1) throw _invalidCertificate(options);
          return _okResponse();
        },
      );
      final provider = IqdbSearchProvider(externalSearchClient: client);
      addTearDown(provider.close);

      final response = await provider.search(_query());

      expect(response.serviceMessage, isNull);
      expect(requests, hasLength(2));
      expect(channels, <ExternalTlsTrustChannel>[
        ExternalTlsTrustChannel.webpki,
        ExternalTlsTrustChannel.androidSecurityContext,
      ]);
      expect(
        _normalizedMultipart(requests[1]),
        _normalizedMultipart(requests[0]),
      );
      expect(
        _normalizedMultipart(requests[0]),
        contains(latin1.decode(_query().bytes)),
      );
    },
  );

  test('does not retry an HTTP 429 response', () async {
    final channels = <ExternalTlsTrustChannel>[];
    var attempts = 0;
    final client = _fallbackClient(
      channels: channels,
      handler: (options, body, _) async {
        attempts++;
        return ResponseBody.fromString('rate limited', 429);
      },
    );
    final provider = IqdbSearchProvider(externalSearchClient: client);
    addTearDown(provider.close);

    final response = await provider.search(_query());

    expect(attempts, 1);
    expect(channels, <ExternalTlsTrustChannel>[ExternalTlsTrustChannel.webpki]);
    expect(response.rateLimited, isTrue);
    expect(response.serviceMessage, 'IQDB: too many requests (429)');
  });

  test('reports the provider-owned total deadline as timeout', () async {
    final adapter = _PendingHttpClientAdapter();
    final dio = Dio(
      BaseOptions(baseUrl: 'https://safe.iqdb.org', followRedirects: false),
    )..httpClientAdapter = adapter;
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

  test('timeout does not enter the certificate fallback channel', () async {
    final channels = <ExternalTlsTrustChannel>[];
    var attempts = 0;
    final client = _fallbackClient(
      channels: channels,
      handler: (options, body, _) {
        attempts++;
        return Completer<ResponseBody>().future;
      },
    );
    final provider = IqdbSearchProvider(
      externalSearchClient: client,
      totalTimeout: const Duration(milliseconds: 40),
    );
    addTearDown(provider.close);
    final token = CancelToken();

    final response = await provider
        .searchWithCancel(_query(), cancelToken: token)
        .timeout(const Duration(seconds: 1));

    expect(attempts, 1);
    expect(channels, <ExternalTlsTrustChannel>[ExternalTlsTrustChannel.webpki]);
    expect(token.isCancelled, isTrue);
    expect(response.serviceMessage, startsWith('IQDB timed out after'));
  });

  test('reports earlier caller cancellation as cancellation', () async {
    final adapter = _PendingHttpClientAdapter();
    final dio = Dio(
      BaseOptions(baseUrl: 'https://safe.iqdb.org', followRedirects: false),
    )..httpClientAdapter = adapter;
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

  test('caller cancellation does not enter the fallback channel', () async {
    final channels = <ExternalTlsTrustChannel>[];
    final started = Completer<void>();
    var attempts = 0;
    final client = _fallbackClient(
      channels: channels,
      handler: (options, body, cancelFuture) {
        attempts++;
        if (!started.isCompleted) started.complete();
        return Completer<ResponseBody>().future;
      },
    );
    final provider = IqdbSearchProvider(
      externalSearchClient: client,
      totalTimeout: const Duration(seconds: 2),
    );
    addTearDown(provider.close);
    final token = CancelToken();

    final pending = provider.searchWithCancel(_query(), cancelToken: token);
    await started.future.timeout(const Duration(seconds: 1));
    token.cancel('user');
    final response = await pending.timeout(const Duration(seconds: 1));

    expect(attempts, 1);
    expect(channels, <ExternalTlsTrustChannel>[ExternalTlsTrustChannel.webpki]);
    expect(response.serviceMessage, 'IQDB search cancelled');
  });

  test('certificate fallback shares one total deadline', () async {
    final channels = <ExternalTlsTrustChannel>[];
    var attempts = 0;
    final client = _fallbackClient(
      channels: channels,
      handler: (options, body, _) async {
        attempts++;
        if (attempts == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          throw _invalidCertificate(options);
        }
        await Future<void>.delayed(const Duration(milliseconds: 180));
        return _okResponse();
      },
    );
    final provider = IqdbSearchProvider(
      externalSearchClient: client,
      totalTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(provider.close);
    final token = CancelToken();

    final response = await provider
        .searchWithCancel(_query(), cancelToken: token)
        .timeout(const Duration(seconds: 1));

    expect(attempts, 2);
    expect(channels, <ExternalTlsTrustChannel>[
      ExternalTlsTrustChannel.webpki,
      ExternalTlsTrustChannel.androidSecurityContext,
    ]);
    expect(token.isCancelled, isTrue);
    expect(response.serviceMessage, startsWith('IQDB timed out after'));
  });
}
