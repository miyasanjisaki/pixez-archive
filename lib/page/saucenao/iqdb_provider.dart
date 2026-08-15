import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:pixez/utils/iqdb_result_parser.dart';
import 'package:pixez/utils/reverse_image_search.dart';

class IqdbSearchProvider implements ReverseImageSearchProvider {
  static const int maxInputBytes = 8 * 1024 * 1024;
  static const Duration defaultTotalTimeout = Duration(seconds: 30);
  static const List<String> _safeServiceIds = [
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '11',
    '13',
  ];

  final Dio dio;
  final Duration totalTimeout;

  IqdbSearchProvider({Dio? dio, this.totalTimeout = defaultTotalTimeout})
    : assert(totalTimeout > Duration.zero),
      dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://safe.iqdb.org',
              connectTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 45),
              receiveTimeout: const Duration(seconds: 45),
              followRedirects: true,
              headers: const {
                'Accept': 'text/html,application/xhtml+xml',
                'User-Agent': 'PixEz-Archive reverse-image-search',
              },
            ),
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

    final form = FormData();
    for (final serviceId in _safeServiceIds) {
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

    final activeCancelToken = cancelToken ?? CancelToken();

    try {
      final response = await dio
          .post<dynamic>('/', data: form, cancelToken: activeCancelToken)
          .timeout(
            totalTimeout,
            onTimeout: () {
              if (activeCancelToken.isCancelled) {
                throw DioException(
                  requestOptions: RequestOptions(path: '/'),
                  type: DioExceptionType.cancel,
                  error: 'IQDB search cancelled',
                );
              }
              // The deadline owns this request token. Callers that need to
              // keep other providers alive must pass a dedicated IQDB token.
              activeCancelToken.cancel('IQDB total timeout');
              throw TimeoutException('IQDB total timeout', totalTimeout);
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
        return const ReverseImageProviderResponse(
          serviceMessage: 'IQDB search cancelled',
        );
      }
      final status = error.response?.statusCode;
      return ReverseImageProviderResponse(
        rateLimited: status == 429,
        serviceMessage: status == null
            ? 'IQDB network error'
            : 'IQDB request failed ($status)',
      );
    }
  }

  void close() => dio.close(force: true);
}
