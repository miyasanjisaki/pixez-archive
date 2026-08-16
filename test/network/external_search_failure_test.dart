import 'dart:io' show OSError, SocketException;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/network/external_search_failure.dart';
import 'package:rhttp/rhttp.dart';

DioException _error({
  DioExceptionType type = DioExceptionType.connectionError,
  Object? cause,
  int? status,
}) {
  final request = RequestOptions(path: '/search');
  return DioException(
    requestOptions: request,
    type: type,
    error: cause,
    response: status == null
        ? null
        : Response<void>(requestOptions: request, statusCode: status),
  );
}

RhttpWrappedClientException _wrapped(RhttpException exception) {
  return RhttpWrappedClientException(
    'redacted transport failure',
    Uri.parse('https://secret.example/search?token=private'),
    exception,
  );
}

void main() {
  test('keeps HTTP rate-limit and blocked status actionable', () {
    expect(
      describeExternalSearchFailure('SauceNAO', _error(status: 429)),
      'SauceNAO: too many requests (429)',
    );
    expect(
      describeExternalSearchFailure('SauceNAO', _error(status: 403)),
      'SauceNAO: request blocked (403)',
    );
  });

  test('classifies Dio timeouts without exposing request details', () {
    final message = describeExternalSearchFailure(
      'IQDB',
      _error(type: DioExceptionType.receiveTimeout),
    );

    expect(message, 'IQDB: timeout');
    expect(message, isNot(contains('secret.example')));
  });

  test('classifies wrapped rhttp DNS failures and redacts the cause', () {
    final request = HttpRequest(url: 'https://secret.example/search');
    final cause = RhttpConnectionException(
      request,
      'dns lookup failed for secret.example via 192.0.2.10',
    );

    final message = describeExternalSearchFailure(
      'SauceNAO',
      _error(cause: _wrapped(cause)),
    );

    expect(message, 'SauceNAO: DNS lookup failed');
    expect(message, isNot(contains('secret.example')));
    expect(message, isNot(contains('192.0.2.10')));
  });

  test('classifies wrapped rhttp certificate failures', () {
    final request = HttpRequest(url: 'https://secret.example/search');
    final cause = RhttpInvalidCertificateException(
      request: request,
      message: 'certificate for secret.example was rejected',
    );

    expect(
      describeExternalSearchFailure('IQDB', _error(cause: _wrapped(cause))),
      'IQDB: TLS verification failed',
    );
  });

  test('classifies socket failures without returning raw OS details', () {
    const cause = SocketException(
      'Connection refused by 127.0.0.1:8080',
      osError: OSError('refused', 10061),
    );

    final message = describeExternalSearchFailure('IQDB', _error(cause: cause));

    expect(message, 'IQDB: connection failed');
    expect(message, isNot(contains('127.0.0.1')));
  });
}
