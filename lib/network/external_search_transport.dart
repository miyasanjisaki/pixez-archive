import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http/http.dart' as http;
import 'package:pixez/network/external_search_failure.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:rhttp/rhttp.dart' as r;

const Map<String, Object> _externalSearchHeaders = {
  HttpHeaders.acceptHeader: 'text/html,application/xhtml+xml',
  HttpHeaders.userAgentHeader: 'PixEz-Archive reverse-image-search',
};

typedef ExternalSearchDioFactory =
    Future<Dio> Function({
      required String baseUrl,
      required NetworkMode networkMode,
      required ExternalTlsTrustChannel trustChannel,
    });

/// Creates a Dio client backed by either verified rhttp trust or the narrowly
/// allowed Android system [SecurityContext] fallback.
///
/// The caller owns the returned client and must close it. A fresh client is
/// intentionally created for each provider owner so cookies and connection
/// state are not shared between unrelated external services.
Future<Dio> createExternalSearchDio({
  required String baseUrl,
  required NetworkMode networkMode,
  required ExternalTlsTrustChannel trustChannel,
}) async {
  final baseUri = _validatedExternalBaseUri(baseUrl);
  final dio = Dio(buildExternalSearchBaseOptions(baseUrl));
  if (trustChannel == ExternalTlsTrustChannel.androidSecurityContext) {
    if (!Platform.isAndroid || !_isDartIoFallbackOrigin(baseUri)) {
      throw StateError(
        'Android system trust is restricted to fixed reverse-search hosts',
      );
    }
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () =>
          HttpClient(context: SecurityContext.defaultContext),
    );
    return dio;
  }

  final compatibleClient = await r.RhttpCompatibleClient.create(
    settings: buildExternalSearchClientSettings(
      networkMode,
      trustChannel: trustChannel,
    ),
  );
  dio.httpClientAdapter = CancelAwareConversionLayerAdapter(compatibleClient);
  return dio;
}

/// Builds the provider-level Dio policy without opening a connection.
BaseOptions buildExternalSearchBaseOptions(String baseUrl) {
  _validatedExternalBaseUri(baseUrl);
  return BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 20),
    sendTimeout: const Duration(seconds: 45),
    receiveTimeout: const Duration(seconds: 45),
    followRedirects: false,
    headers: _externalSearchHeaders,
  );
}

Uri _validatedExternalBaseUri(String baseUrl) {
  final uri = Uri.parse(baseUrl);
  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw ArgumentError.value(
      baseUrl,
      'baseUrl',
      'External search requires an HTTPS origin without user information',
    );
  }
  return uri;
}

bool _isDartIoFallbackOrigin(Uri uri) {
  return (uri.host == 'saucenao.com' || uri.host == 'safe.iqdb.org') &&
      uri.port == 443 &&
      (uri.path.isEmpty || uri.path == '/') &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

/// Builds the native transport policy independently so its security and
/// deadline invariants can be verified without opening a network connection.
r.ClientSettings buildExternalSearchClientSettings(
  NetworkMode networkMode, {
  ExternalTlsTrustChannel trustChannel = ExternalTlsTrustChannel.webpki,
}) {
  final networkSettings = PixezNetworkSettings.forExternalService(
    networkMode,
    trustChannel: trustChannel,
  );
  return networkSettings.copyWith(
    timeoutSettings: const r.TimeoutSettings(
      timeout: Duration(seconds: 45),
      connectTimeout: Duration(seconds: 20),
    ),
  );
}

const _kIsWebInterop = bool.fromEnvironment('dart.library.js_interop');
const _kIsWebUtil = bool.fromEnvironment('dart.library.js_util');
const _kIsWeb = _kIsWebInterop || _kIsWebUtil || identical(0, 0.0);

/// Dio-to-package:http bridge that preserves Dio cancellation.
///
/// The upstream compatibility adapter currently ignores [cancelFuture]. This
/// bridge emits package:http abortable requests instead; RhttpCompatibleClient
/// translates their abort trigger into rhttp's native CancelToken.
class CancelAwareConversionLayerAdapter implements HttpClientAdapter {
  CancelAwareConversionLayerAdapter(this.client);

  final http.Client client;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final abortTrigger = cancelFuture?.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    try {
      final request = await _fromOptionsAndStream(
        options,
        requestStream,
        abortTrigger,
      );
      final response = await client.send(request);
      return ResponseBody(
        _mapResponseStream(response.stream, options),
        response.statusCode,
        statusMessage: response.reasonPhrase,
        isRedirect: response.isRedirect,
        headers: Map<String, List<String>>.fromEntries(
          response.headers.entries.map(
            (entry) => MapEntry(entry.key, <String>[entry.value]),
          ),
        ),
      );
    } on http.RequestAbortedException catch (error) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
        error: error,
      );
    }
  }

  @override
  void close({bool force = false}) => client.close();

  Future<http.BaseRequest> _fromOptionsAndStream(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? abortTrigger,
  ) async {
    final http.BaseRequest request;
    if (_kIsWeb && requestStream != null) {
      final normalRequest = http.AbortableRequest(
        options.method,
        options.uri,
        abortTrigger: abortTrigger,
      );
      normalRequest.bodyBytes = await _collectRequestBytes(
        requestStream,
        abortTrigger,
        options.uri,
      );
      request = normalRequest;
    } else if (requestStream != null) {
      final streamedRequest = http.AbortableStreamedRequest(
        options.method,
        options.uri,
        abortTrigger: abortTrigger,
      );
      final subscription = requestStream.listen(
        streamedRequest.sink.add,
        onError: streamedRequest.sink.addError,
        onDone: streamedRequest.sink.close,
        cancelOnError: true,
      );
      final abortCleanup = abortTrigger?.then<void>((_) async {
        try {
          await subscription.cancel();
        } catch (_) {}
        try {
          await streamedRequest.sink.close();
        } catch (_) {}
      });
      if (abortCleanup != null) unawaited(abortCleanup);
      request = streamedRequest;
    } else {
      request = http.AbortableRequest(
        options.method,
        options.uri,
        abortTrigger: abortTrigger,
      );
    }
    request.headers.addAll(
      Map<String, String>.fromEntries(
        options.headers.entries.map(
          (entry) => MapEntry(entry.key, entry.value.toString().trim()),
        ),
      ),
    );
    request
      ..followRedirects = options.followRedirects
      ..maxRedirects = options.maxRedirects
      ..persistentConnection = options.persistentConnection;
    return request;
  }

  Future<Uint8List> _collectRequestBytes(
    Stream<Uint8List> requestStream,
    Future<void>? abortTrigger,
    Uri uri,
  ) async {
    final completer = Completer<Uint8List>();
    final sink = ByteConversionSink.withCallback(
      (bytes) => completer.complete(
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      ),
    );
    final subscription = requestStream.listen(
      sink.add,
      onError: completer.completeError,
      onDone: sink.close,
      cancelOnError: true,
    );
    if (abortTrigger == null) return completer.future;
    final aborted = abortTrigger.then<Uint8List>((_) async {
      try {
        await subscription.cancel();
      } catch (_) {}
      throw http.RequestAbortedException(uri);
    });
    return Future.any(<Future<Uint8List>>[completer.future, aborted]);
  }

  Stream<Uint8List> _mapResponseStream(
    Stream<List<int>> stream,
    RequestOptions options,
  ) async* {
    try {
      await for (final chunk in stream) {
        yield chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      }
    } on http.RequestAbortedException catch (error) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
        error: error,
      );
    }
  }
}

/// Owns provider-specific transports keyed by both network mode and verified
/// trust channel.
class ExternalSearchDioClient {
  ExternalSearchDioClient({
    required this.baseUrl,
    required this.networkModeProvider,
    Dio? injectedDio,
    ExternalTlsHostPlan? trustPlan,
    ExternalSearchDioFactory factory = createExternalSearchDio,
  }) : _injectedDio = injectedDio,
       _factory = factory,
       _baseUri = _validatedExternalBaseUri(baseUrl),
       trustPlan = _validatedTrustPlan(
         baseUrl,
         trustPlan ??
             PixezNetworkSettings.externalTlsHostPlan(
               _validatedExternalBaseUri(baseUrl).host,
             ),
       );

  final String baseUrl;
  final NetworkMode Function() networkModeProvider;
  final ExternalTlsHostPlan trustPlan;
  final Uri _baseUri;
  final Dio? _injectedDio;
  final ExternalSearchDioFactory _factory;

  final Map<_ExternalSearchClientKey, Dio> _ownedClients =
      <_ExternalSearchClientKey, Dio>{};
  final Map<_ExternalSearchClientKey, Future<Dio>> _pendingCreations =
      <_ExternalSearchClientKey, Future<Dio>>{};
  final Map<_ExternalSearchClientKey, Map<Dio, int>> _activeLeases =
      <_ExternalSearchClientKey, Map<Dio, int>>{};
  final Set<Dio> _retiredClients = <Dio>{};
  final Set<Dio> _originGuardedClients = <Dio>{};
  bool _closed = false;

  /// Runs one complete request while holding a lease on its transport.
  ///
  /// A network-mode change retires the previous transport, but does not close
  /// it until its active request has finished. This avoids cancelling an
  /// upload merely because settings changed in another page.
  Future<T> run<T>(Future<T> Function(Dio dio) request) async {
    return _runOnChannel(trustPlan.primary, request);
  }

  /// Runs [attempt] on the host's ordered, fully verified trust channels.
  ///
  /// [attempt] is invoked again for every permitted fallback, so callers must
  /// create a new request body (especially FormData and MultipartFile) inside
  /// this callback. Cancellation tokens and total deadlines remain owned by
  /// the caller and should be shared across attempts.
  ///
  /// Only a typed rhttp invalid-certificate failure advances to the next
  /// channel. Every other failure is rethrown without replaying the request.
  Future<T> runWithTlsFallback<T>(Future<T> Function(Dio dio) attempt) async {
    final channels = trustPlan.channels.toList(growable: false);
    for (var index = 0; index < channels.length; index++) {
      try {
        return await _runOnChannel(channels[index], attempt);
      } catch (error, stackTrace) {
        final canFallback =
            index + 1 < channels.length &&
            isExternalSearchInvalidCertificateFailure(error);
        if (!canFallback) Error.throwWithStackTrace(error, stackTrace);
      }
    }
    throw StateError('External TLS host plan has no channel');
  }

  Future<T> _runOnChannel<T>(
    ExternalTlsTrustChannel trustChannel,
    Future<T> Function(Dio dio) request,
  ) async {
    final lease = await _acquire(trustChannel);
    try {
      return await request(lease.client);
    } finally {
      _release(lease);
    }
  }

  Future<_ExternalSearchClientLease> _acquire(
    ExternalTlsTrustChannel trustChannel,
  ) async {
    if (_closed) throw StateError('External search client is closed');
    final key = _ExternalSearchClientKey(networkModeProvider(), trustChannel);
    final injected = _injectedDio;
    if (injected != null) {
      return _retain(key, injected);
    }

    _retireOtherModes(key.networkMode);
    final existing = _ownedClients[key];
    if (existing != null) {
      return _retain(key, existing);
    }

    final pending = _pendingCreations[key];
    if (pending != null) {
      return _retain(key, await pending);
    }

    final creation = _createOwnedClient(key);
    _pendingCreations[key] = creation;
    try {
      final client = await creation;
      return _retain(key, client);
    } finally {
      if (identical(_pendingCreations[key], creation)) {
        _pendingCreations.remove(key);
      }
    }
  }

  Future<Dio> _createOwnedClient(_ExternalSearchClientKey key) async {
    final client = await _factory(
      baseUrl: baseUrl,
      networkMode: key.networkMode,
      trustChannel: key.trustChannel,
    );
    if (_closed) {
      client.close(force: true);
      throw StateError('External search client is closed');
    }
    _ownedClients[key] = client;
    return client;
  }

  _ExternalSearchClientLease _retain(_ExternalSearchClientKey key, Dio client) {
    _installOriginGuard(client);
    final clients = _activeLeases.putIfAbsent(key, () => <Dio, int>{});
    clients[client] = (clients[client] ?? 0) + 1;
    return _ExternalSearchClientLease(key, client);
  }

  void _installOriginGuard(Dio client) {
    if (!_originGuardedClients.add(client)) return;
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final uri = options.uri;
          final sameOrigin =
              uri.scheme == 'https' &&
              uri.host == _baseUri.host &&
              uri.port == _baseUri.port &&
              uri.userInfo.isEmpty;
          if (!sameOrigin || options.followRedirects) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.unknown,
                error: StateError(
                  'External search request violated its fixed-origin policy',
                ),
              ),
            );
            return;
          }
          handler.next(options);
        },
      ),
    );
  }

  void _release(_ExternalSearchClientLease lease) {
    final clients = _activeLeases[lease.key];
    final remaining = (clients?[lease.client] ?? 1) - 1;
    if (remaining > 0) {
      clients![lease.client] = remaining;
      return;
    }
    clients?.remove(lease.client);
    if (clients?.isEmpty ?? false) _activeLeases.remove(lease.key);
    if (_retiredClients.remove(lease.client)) {
      lease.client.close(force: true);
    }
  }

  void _retire(_ExternalSearchClientKey key, Dio client) {
    if ((_activeLeases[key]?[client] ?? 0) > 0) {
      _retiredClients.add(client);
    } else {
      client.close(force: true);
    }
  }

  void _retireOtherModes(NetworkMode mode) {
    final staleEntries = _ownedClients.entries
        .where((entry) => entry.key.networkMode != mode)
        .toList(growable: false);
    for (final entry in staleEntries) {
      _ownedClients.remove(entry.key);
      _retire(entry.key, entry.value);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _injectedDio?.close(force: true);
    for (final client in _ownedClients.values.toSet()) {
      client.close(force: true);
    }
    _ownedClients.clear();
    _originGuardedClients.clear();
    for (final client in _retiredClients) {
      client.close(force: true);
    }
    _retiredClients.clear();
    for (final pending in _pendingCreations.values) {
      // If setup is still in native code, close the client as soon as it is
      // returned and consume setup errors during disposal.
      unawaited(
        pending.then<void>((client) {
          client.close(force: true);
        }, onError: (Object _, StackTrace __) {}),
      );
    }
    _pendingCreations.clear();
  }
}

ExternalTlsHostPlan _validatedTrustPlan(
  String baseUrl,
  ExternalTlsHostPlan plan,
) {
  final uri = _validatedExternalBaseUri(baseUrl);
  final channels = plan.channels.toList(growable: false);
  if (channels.isEmpty || channels.toSet().length != channels.length) {
    throw ArgumentError.value(plan, 'trustPlan', 'Channels must be unique');
  }
  if (channels.contains(ExternalTlsTrustChannel.androidSecurityContext) &&
      !_isDartIoFallbackOrigin(uri)) {
    throw ArgumentError.value(
      plan,
      'trustPlan',
      'Android system trust is restricted to fixed reverse-search hosts',
    );
  }
  return ExternalTlsHostPlan(
    primary: plan.primary,
    invalidCertificateFallbacks: List<ExternalTlsTrustChannel>.unmodifiable(
      plan.invalidCertificateFallbacks,
    ),
  );
}

class _ExternalSearchClientKey {
  const _ExternalSearchClientKey(this.networkMode, this.trustChannel);

  final NetworkMode networkMode;
  final ExternalTlsTrustChannel trustChannel;

  @override
  bool operator ==(Object other) {
    return other is _ExternalSearchClientKey &&
        other.networkMode == networkMode &&
        other.trustChannel == trustChannel;
  }

  @override
  int get hashCode => Object.hash(networkMode, trustChannel);
}

class _ExternalSearchClientLease {
  const _ExternalSearchClientLease(this.key, this.client);

  final _ExternalSearchClientKey key;
  final Dio client;
}
