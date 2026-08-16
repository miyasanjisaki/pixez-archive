import 'dart:io';

import 'package:dio/dio.dart';
import 'package:rhttp/rhttp.dart';

/// Converts transport failures into useful but privacy-safe diagnostics.
///
/// Raw exception messages are deliberately not returned because they can
/// contain full request URLs, local proxy addresses, or resolver details.
String describeExternalSearchFailure(String provider, DioException error) {
  final status = error.response?.statusCode;
  if (status == 429) return '$provider: too many requests (429)';
  if (status == 403) return '$provider: request blocked (403)';
  if (status != null) return '$provider: request failed ($status)';

  if (_isTimeoutType(error.type)) return '$provider: timeout';

  final cause = _unwrapRhttpCause(error.error);
  if (cause is RhttpTimeoutException) return '$provider: timeout';
  if (cause is RhttpInvalidCertificateException || cause is TlsException) {
    return '$provider: TLS verification failed';
  }
  if (cause is SocketException) {
    return _classifiedConnectionMessage(provider, cause.message);
  }
  if (cause is RhttpConnectionException) {
    return _classifiedConnectionMessage(provider, cause.message);
  }

  if (error.type == DioExceptionType.connectionError) {
    return '$provider: connection failed';
  }
  return '$provider: network error';
}

bool _isTimeoutType(DioExceptionType type) {
  return type == DioExceptionType.connectionTimeout ||
      type == DioExceptionType.sendTimeout ||
      type == DioExceptionType.receiveTimeout;
}

Object? _unwrapRhttpCause(Object? cause) {
  if (cause is RhttpWrappedClientException) return cause.rhttpException;
  return cause;
}

String _classifiedConnectionMessage(String provider, String rawMessage) {
  final message = rawMessage.toLowerCase();
  if (message.contains('dns') ||
      message.contains('failed host lookup') ||
      message.contains('no such host') ||
      message.contains('name or service not known') ||
      message.contains('nodename nor servname') ||
      message.contains('resolve')) {
    return '$provider: DNS lookup failed';
  }
  if (message.contains('certificate') ||
      message.contains('handshake') ||
      message.contains('tls') ||
      message.contains('ssl')) {
    return '$provider: TLS verification failed';
  }
  if (message.contains('timed out') || message.contains('timeout')) {
    return '$provider: timeout';
  }
  return '$provider: connection failed';
}
