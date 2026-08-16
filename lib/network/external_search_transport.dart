import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
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
    });

/// Creates a Dio client backed by the same verified rhttp transport used by
/// the rest of PixEz.
///
/// The caller owns the returned client and must close it. A fresh client is
/// intentionally created for each provider owner so cookies and connection
/// state are not shared between unrelated external services.
Future<Dio> createExternalSearchDio({
  required String baseUrl,
  required NetworkMode networkMode,
}) async {
  final compatibleClient = await r.RhttpCompatibleClient.create(
    settings: buildExternalSearchClientSettings(networkMode),
  );
  return Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 45),
      receiveTimeout: const Duration(seconds: 45),
      followRedirects: true,
      headers: _externalSearchHeaders,
    ),
  )..httpClientAdapter = CancelAwareConversionLayerAdapter(compatibleClient);
}

/// Builds the native transport policy independently so its security and
/// deadline invariants can be verified without opening a network connection.
r.ClientSettings buildExternalSearchClientSettings(NetworkMode networkMode) {
  final networkSettings = PixezNetworkSettings.forExternalService(networkMode);
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

/// Owns one provider-specific client and rebuilds it when the selected network
/// mode changes. This matters for long-lived search pages: a mode switch must
/// affect the next request without requiring an app restart.
class ExternalSearchDioClient {
  ExternalSearchDioClient({
    required this.baseUrl,
    required this.networkModeProvider,
    Dio? injectedDio,
    ExternalSearchDioFactory factory = createExternalSearchDio,
  }) : _injectedDio = injectedDio,
       _factory = factory;

  final String baseUrl;
  final NetworkMode Function() networkModeProvider;
  final Dio? _injectedDio;
  final ExternalSearchDioFactory _factory;

  Dio? _ownedDio;
  NetworkMode? _ownedMode;
  Future<Dio>? _pendingCreation;
  final Map<Dio, int> _activeRequests = <Dio, int>{};
  final Set<Dio> _retiredClients = <Dio>{};
  bool _closed = false;

  /// Runs one complete request while holding a lease on its transport.
  ///
  /// A network-mode change retires the previous transport, but does not close
  /// it until its active request has finished. This avoids cancelling an
  /// upload merely because settings changed in another page.
  Future<T> run<T>(Future<T> Function(Dio dio) request) async {
    final client = await _acquire();
    try {
      return await request(client);
    } finally {
      _release(client);
    }
  }

  Future<Dio> _acquire() async {
    if (_closed) throw StateError('External search client is closed');
    final injected = _injectedDio;
    if (injected != null) {
      _retain(injected);
      return injected;
    }

    final requestedMode = networkModeProvider();
    final existing = _ownedDio;
    if (existing != null && _ownedMode == requestedMode) {
      _retain(existing);
      return existing;
    }

    final pending = _pendingCreation;
    if (pending != null) {
      // Do not create competing owners. Once the earlier setup settles, the
      // recursive call observes the latest mode and replaces it if necessary.
      await pending;
      return _acquire();
    }

    if (existing != null) _retire(existing);
    _ownedDio = null;
    _ownedMode = null;

    final creation = _createOwnedClient(requestedMode);
    _pendingCreation = creation;
    try {
      final client = await creation;
      _retain(client);
      return client;
    } finally {
      if (identical(_pendingCreation, creation)) {
        _pendingCreation = null;
      }
    }
  }

  Future<Dio> _createOwnedClient(NetworkMode mode) async {
    final client = await _factory(baseUrl: baseUrl, networkMode: mode);
    if (_closed) {
      client.close(force: true);
      throw StateError('External search client is closed');
    }
    _ownedDio = client;
    _ownedMode = mode;
    return client;
  }

  void _retain(Dio client) {
    _activeRequests[client] = (_activeRequests[client] ?? 0) + 1;
  }

  void _release(Dio client) {
    final remaining = (_activeRequests[client] ?? 1) - 1;
    if (remaining > 0) {
      _activeRequests[client] = remaining;
      return;
    }
    _activeRequests.remove(client);
    if (_retiredClients.remove(client)) client.close(force: true);
  }

  void _retire(Dio client) {
    if ((_activeRequests[client] ?? 0) > 0) {
      _retiredClients.add(client);
    } else {
      client.close(force: true);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _injectedDio?.close(force: true);
    _ownedDio?.close(force: true);
    for (final client in _retiredClients) {
      client.close(force: true);
    }
    _retiredClients.clear();
    final pending = _pendingCreation;
    if (pending != null) {
      // If setup is still in native code, close the client as soon as it is
      // returned and consume setup errors during disposal.
      unawaited(
        pending.then<void>((client) {
          if (!identical(client, _ownedDio)) client.close(force: true);
        }, onError: (Object _, StackTrace __) {}),
      );
    }
  }
}
