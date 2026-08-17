import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:pixez/network/external_search_failure.dart';
import 'package:pixez/network/external_search_transport.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/utils/iqdb_result_parser.dart';
import 'package:pixez/utils/reverse_image_search.dart';

class IqdbSearchProvider implements ReverseImageSearchProvider {
  static const int maxInputBytes = 8 * 1024 * 1024;
  static const Duration defaultTotalTimeout = Duration(seconds: 45);
  static const List<String> _safeServiceIds = ['1', '2', '3', '11'];

  final ExternalSearchDioClient _dioClient;
  final Duration totalTimeout;

  IqdbSearchProvider({
    Dio? dio,
    ExternalSearchDioClient? externalSearchClient,
    NetworkMode networkMode = NetworkMode.standard,
    NetworkMode Function()? networkModeProvider,
    this.totalTimeout = defaultTotalTimeout,
  }) : assert(totalTimeout > Duration.zero),
       assert(dio == null || externalSearchClient == null),
       _dioClient =
           externalSearchClient ??
           ExternalSearchDioClient(
             baseUrl: 'https://safe.iqdb.org',
             networkModeProvider: networkModeProvider ?? () => networkMode,
             injectedDio: dio,
           );

  @override
  String get id => 'iqdb';

  @override
  Future<ReverseImageProviderResponse> search(ReverseImageQuery query) =>
      searchWithCancel(query);

  Future<ReverseImageProviderResponse> searchWithCancel(
    ReverseImageQuery query, {
    CancelToken? cancelToken,
  }) async {
    if (query.bytes.length > maxInputBytes) {
      return const ReverseImageProviderResponse(
        serviceMessage: 'IQDB image exceeds the 8 MB limit',
      );
    }

    final activeCancelToken = cancelToken ?? CancelToken();
    final stopwatch = Stopwatch()..start();
    var deadlineExpired = false;

    TimeoutException totalTimeoutError() {
      deadlineExpired = true;
      // The provider owns this total deadline. Callers that need other
      // providers to keep running must pass a dedicated IQDB token, as
      // SauceStore does.
      if (!activeCancelToken.isCancelled) {
        activeCancelToken.cancel('IQDB total timeout');
      }
      return TimeoutException('IQDB total timeout', totalTimeout);
    }

    try {
      final response = await _dioClient
          .runWithTlsFallback((dio) {
            if (activeCancelToken.isCancelled) {
              if (deadlineExpired) throw totalTimeoutError();
              throw _cancelledRequest(activeCancelToken);
            }
            final remaining = totalTimeout - stopwatch.elapsed;
            if (remaining <= Duration.zero) {
              throw totalTimeoutError();
            }
            // A FormData/MultipartFile is single-use once Dio finalizes it.
            // The callback is invoked again for the alternate trust channel,
            // so every attempt must start from the immutable query bytes.
            return dio
                .post<dynamic>(
                  '/',
                  data: _buildFormData(query),
                  cancelToken: activeCancelToken,
                )
                .timeout(
                  remaining,
                  onTimeout: () {
                    if (activeCancelToken.isCancelled && !deadlineExpired) {
                      throw _cancelledRequest(activeCancelToken);
                    }
                    throw totalTimeoutError();
                  },
                );
          })
          .timeout(
            totalTimeout,
            onTimeout: () {
              if (activeCancelToken.isCancelled && !deadlineExpired) {
                throw _cancelledRequest(activeCancelToken);
              }
              throw totalTimeoutError();
            },
          );
      final html = switch (response.data) {
        String value => value,
        List<int> value => utf8.decode(value, allowMalformed: true),
        _ => response.data.toString(),
      };
      return ReverseImageProviderResponse(
        hits: parseIqdbResults(html, probe: query.probe),
      );
    } on IqdbResponseException catch (error) {
      return ReverseImageProviderResponse(serviceMessage: error.message);
    } on TimeoutException {
      return ReverseImageProviderResponse(
        serviceMessage: 'IQDB timed out after ${totalTimeout.inSeconds}s',
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        if (deadlineExpired) {
          return ReverseImageProviderResponse(
            serviceMessage: 'IQDB timed out after ${totalTimeout.inSeconds}s',
          );
        }
        return const ReverseImageProviderResponse(
          serviceMessage: 'IQDB search cancelled',
        );
      }
      final status = error.response?.statusCode;
      return ReverseImageProviderResponse(
        rateLimited: status == 429,
        serviceMessage: describeExternalSearchFailure('IQDB', error),
      );
    }
  }

  void close() => _dioClient.close();
}

FormData _buildFormData(ReverseImageQuery query) {
  final form = FormData();
  for (final serviceId in IqdbSearchProvider._safeServiceIds) {
    form.fields.add(MapEntry('service[]', serviceId));
  }
  form.files.add(
    MapEntry(
      'file',
      MultipartFile.fromBytes(
        query.bytes,
        filename: 'pixez_reverse_search.${query.extension}',
      ),
    ),
  );
  return form;
}

DioException _cancelledRequest(CancelToken cancelToken) {
  return DioException(
    requestOptions: RequestOptions(path: '/'),
    type: DioExceptionType.cancel,
    error: cancelToken.cancelError ?? 'IQDB search cancelled',
  );
}
