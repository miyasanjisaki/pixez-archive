import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:flutter/foundation.dart' as foundation;
import 'package:image/image.dart' as image;
import 'package:pixez/er/hoster.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/download_identity_index.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/utils/bookmark_visual_search.dart';
import 'package:pixez/utils/image_perceptual_hash.dart';

const String _pixivBookmarkPath = '/v1/user/bookmarks/illust';
const String _pixivApiHost = 'app-api.pixiv.net';
const String _pixivImageHost = 'i.pximg.net';
// Keep the query-image boundary aligned with the local identity and sanitized
// preview paths. Otherwise a 24-32 MP image can pass local inspection but fail
// the bookmark scan before the first Pixiv request is made.
const int maximumBookmarkFingerprintPixels = 32 * 1024 * 1024;
const int _maximumBookmarkFingerprintBytes = 32 * 1024 * 1024;

/// Returns a short, sanitized explanation suitable for the search-progress UI.
/// Never surface request URLs, response bodies, account IDs, or access tokens.
String describeBookmarkVisualSearchFailure(Object? error) {
  if (error is BookmarkVisualQueryImageException) {
    return 'Selected image could not be decoded for bookmark comparison';
  }
  if (error is FormatException) {
    return 'Pixiv bookmark data could not be processed';
  }
  if (error is TimeoutException) {
    return 'Pixiv bookmark request timed out';
  }
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      return 'Pixiv login expired or bookmark access was denied';
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return 'Pixiv bookmark request timed out';
    }
    if (status != null) return 'Pixiv bookmark request failed ($status)';
    return 'Pixiv bookmark network request failed';
  }
  return 'Bookmark scan failed';
}

class PixivCurrentUserBookmarkVisualSource
    implements CurrentUserBookmarkVisualSource {
  final ApiClient client;
  final int? Function() currentUserIdProvider;
  final Duration requestTimeout;

  const PixivCurrentUserBookmarkVisualSource({
    required this.client,
    required this.currentUserIdProvider,
    this.requestTimeout = const Duration(seconds: 30),
  }) : assert(requestTimeout > Duration.zero);

  @override
  int? get currentUserId => currentUserIdProvider();

  @override
  Future<BookmarkVisualPage> loadPage({
    required int expectedUserId,
    required BookmarkVisibility visibility,
    required int? offset,
    required BookmarkVisualCancellationToken cancellationToken,
  }) async {
    _verifyCurrentAccount(expectedUserId);
    final dioCancelToken = CancelToken();
    void cancelRequest() {
      if (!dioCancelToken.isCancelled) {
        dioCancelToken.cancel('Bookmark visual page request cancelled');
      }
    }

    cancellationToken.addListener(cancelRequest);
    try {
      final response = await client.httpClient
          .get<Object?>(
            _pixivBookmarkPath,
            queryParameters: <String, Object>{
              'user_id': expectedUserId,
              'restrict': visibility.name,
              if (offset != null) 'offset': offset,
            },
            options: client.options
                .copyWith(policy: CachePolicy.refresh)
                .toOptions()
                .copyWith(
                  connectTimeout: requestTimeout,
                  sendTimeout: requestTimeout,
                  receiveTimeout: requestTimeout,
                ),
            cancelToken: dioCancelToken,
          )
          .timeout(
            requestTimeout,
            onTimeout: () {
              cancelRequest();
              throw TimeoutException(
                'Pixiv bookmark page request timed out',
                requestTimeout,
              );
            },
          );
      _verifyCurrentAccount(expectedUserId);
      return parsePixivBookmarkVisualPage(
        _jsonMap(response.data),
        expectedUserId: expectedUserId,
        visibility: visibility,
      );
    } finally {
      cancellationToken.removeListener(cancelRequest);
    }
  }

  void _verifyCurrentAccount(int expectedUserId) {
    if (currentUserIdProvider() != expectedUserId) {
      throw const BookmarkVisualAuthorizationException(
        'The selected Pixiv account changed during bookmark search',
      );
    }
  }
}

class PixivBookmarkVisualImageFetcher implements BookmarkVisualImageFetcher {
  final Dio client;
  final int maximumImageBytes;

  const PixivBookmarkVisualImageFetcher({
    required this.client,
    this.maximumImageBytes = 8 * 1024 * 1024,
  }) : assert(maximumImageBytes > 0);

  @override
  Future<Uint8List> fetch(
    BookmarkVisualImageReference image,
    BookmarkVisualCancellationToken cancellationToken,
  ) async {
    final uri = Uri.tryParse(image.url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.toLowerCase() != _pixivImageHost) {
      throw const FormatException('Refused a non-Pixiv bookmark image URL');
    }

    final dioCancelToken = CancelToken();
    var exceededLimit = false;
    void cancelRequest() {
      if (!dioCancelToken.isCancelled) {
        dioCancelToken.cancel('Bookmark visual search cancelled');
      }
    }

    cancellationToken.addListener(cancelRequest);
    try {
      final response = await client.get<List<int>>(
        image.url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: Hoster.header(url: image.url),
        ),
        cancelToken: dioCancelToken,
        onReceiveProgress: (received, total) {
          if (received > maximumImageBytes && !dioCancelToken.isCancelled) {
            exceededLimit = true;
            dioCancelToken.cancel('Pixiv bookmark image exceeded size limit');
          }
        },
      );
      final data = response.data;
      if (data == null || data.isEmpty) {
        throw const FormatException('Pixiv returned an empty image');
      }
      if (data.length > maximumImageBytes) {
        throw const FormatException('Pixiv bookmark image exceeded size limit');
      }
      return data is Uint8List ? data : Uint8List.fromList(data);
    } on DioException {
      if (exceededLimit) {
        throw const FormatException('Pixiv bookmark image exceeded size limit');
      }
      rethrow;
    } finally {
      cancellationToken.removeListener(cancelRequest);
    }
  }
}

class FlutterBookmarkVisualFingerprintComputer
    implements BookmarkVisualFingerprintComputer {
  Future<void> _computeTail = Future<void>.value();

  @override
  Future<BookmarkVisualFingerprint> compute(Uint8List bytes) {
    final completer = Completer<BookmarkVisualFingerprint>();
    _computeTail = _computeTail.then((_) async {
      try {
        final fingerprints = await foundation.compute(
          _computeBookmarkVisualFingerprints,
          bytes,
        );
        completer.complete(
          BookmarkVisualFingerprint(
            sha256: fingerprints['sha256']!,
            differenceHash: fingerprints['dhash'],
          ),
        );
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

Map<String, String?> _computeBookmarkVisualFingerprints(Uint8List bytes) =>
    <String, String?>{
      'sha256': computeImageSha256(bytes),
      'dhash': tryComputeDifferenceHash(
        bytes,
        maximumDecodedPixels: maximumBookmarkFingerprintPixels,
        maximumEncodedBytes: _maximumBookmarkFingerprintBytes,
      ),
    };

class DownloadIdentityBookmarkVisualSink implements BookmarkVisualIdentitySink {
  final DownloadIdentityIndex index;

  const DownloadIdentityBookmarkVisualSink(this.index);

  @override
  Future<void> remember(BookmarkVisualIndexRecord record) {
    return index.rememberDigest(
      sha256: record.sha256,
      illustId: record.illustId,
      pageIndex: record.pageIndex,
      fileName: record.fileName,
      differenceHash: record.differenceHash,
    );
  }
}

/// Non-UI controller ready for the image-search page to call.
///
/// A controller owns one search at a time. Starting another search cancels the
/// previous one, and [cancel] also propagates into active Pixiv page requests
/// and Dio image downloads.
class PixivBookmarkVisualSearchController {
  final BookmarkVisualSearchService service;
  final BookmarkVisualMatchConfirmer? matchConfirmer;
  final void Function()? _close;
  BookmarkVisualCancellationToken? _activeToken;
  final Set<BookmarkVisualCancellationToken> _previewTokens =
      <BookmarkVisualCancellationToken>{};

  PixivBookmarkVisualSearchController({
    required this.service,
    this.matchConfirmer,
  }) : _close = null;

  PixivBookmarkVisualSearchController._({
    required this.service,
    required this.matchConfirmer,
    required void Function()? close,
  }) : _close = close;

  bool get isSearching => _activeToken != null;

  static Future<PixivBookmarkVisualSearchController> createDefault({
    BookmarkVisualSearchLimits limits = const BookmarkVisualSearchLimits(),
    int maximumImageBytes = 8 * 1024 * 1024,
    bool enableConfirmedIdentityWrites = true,
    bool allowEarlyExactPerceptualMatch = true,
  }) async {
    final imageClient = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        followRedirects: true,
        maxRedirects: 3,
      ),
    );
    // Bookmark scanning may include private works. Keep preview requests on
    // the authenticated Pixiv response URL instead of rewriting them through
    // a user-configured third-party image source.
    imageClient.httpClientAdapter =
        await ApiClient.createDirectPixivImageClient();

    final source = PixivCurrentUserBookmarkVisualSource(
      client: apiClient,
      currentUserIdProvider: () => int.tryParse(accountStore.now?.userId ?? ''),
    );
    final fingerprintComputer = FlutterBookmarkVisualFingerprintComputer();
    final service = BookmarkVisualSearchService(
      source: source,
      imageFetcher: PixivBookmarkVisualImageFetcher(
        client: imageClient,
        maximumImageBytes: maximumImageBytes,
      ),
      fingerprintComputer: fingerprintComputer,
      limits: limits,
      allowEarlyExactPerceptualMatch: allowEarlyExactPerceptualMatch,
    );
    return PixivBookmarkVisualSearchController._(
      service: service,
      matchConfirmer: enableConfirmedIdentityWrites
          ? BookmarkVisualMatchConfirmer(
              fingerprintComputer: fingerprintComputer,
              identitySink: DownloadIdentityBookmarkVisualSink(
                downloadIdentityIndex,
              ),
            )
          : null,
      close: () => imageClient.close(force: true),
    );
  }

  Future<BookmarkVisualSearchResult> search({
    required Uint8List queryBytes,
    String? queryFileName,
    BookmarkVisualProgressCallback? onProgress,
  }) async {
    cancel();
    final token = BookmarkVisualCancellationToken();
    _activeToken = token;
    try {
      return await service.search(
        queryBytes: queryBytes,
        queryFileName: queryFileName,
        cancellationToken: token,
        onProgress: onProgress,
      );
    } finally {
      if (identical(_activeToken, token)) _activeToken = null;
    }
  }

  void cancel() {
    _activeToken?.cancel();
    _activeToken = null;
  }

  /// Call only after the user accepts the displayed Pixiv candidate.
  Future<bool> confirmMatch({
    required BookmarkVisualSearchResult result,
    required Uint8List queryBytes,
    String? queryFileName,
  }) async {
    final confirmer = matchConfirmer;
    if (confirmer == null) return false;
    return confirmer.confirm(
      result: result,
      queryBytes: queryBytes,
      queryFileName: queryFileName,
    );
  }

  /// Downloads a small, in-memory preview directly from Pixiv for the
  /// confirmation dialog. It deliberately bypasses the app's configurable
  /// third-party image source, because a candidate may come from private
  /// bookmarks.
  Future<Uint8List?> loadCandidatePreview(
    BookmarkVisualCandidate candidate,
  ) async {
    final token = BookmarkVisualCancellationToken();
    _previewTokens.add(token);
    try {
      final bytes = await service.imageFetcher.fetch(
        BookmarkVisualImageReference(
          pageIndex: candidate.pageIndex,
          url: candidate.imageUrl,
        ),
        token,
      );
      if (token.isCancelled) return null;
      return foundation.compute(_buildBookmarkCandidatePreview, bytes);
    } on Object {
      return null;
    } finally {
      _previewTokens.remove(token);
    }
  }

  void dispose() {
    cancel();
    for (final token in _previewTokens.toList(growable: false)) {
      token.cancel();
    }
    _previewTokens.clear();
    _close?.call();
  }
}

Uint8List? _buildBookmarkCandidatePreview(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > _maximumBookmarkFingerprintBytes) {
    return null;
  }
  try {
    final decoder = image.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width > maximumBookmarkFingerprintPixels ~/ info.height) {
      return null;
    }
    final decoded = image.decodeImage(bytes);
    if (decoded == null) return null;
    final oriented =
        decoded.exif.imageIfd.hasOrientation &&
            decoded.exif.imageIfd.orientation != 1
        ? image.bakeOrientation(decoded)
        : decoded;
    final preview = oriented.width >= oriented.height
        ? image.copyResize(
            oriented,
            width: oriented.width > 512 ? 512 : oriented.width,
          )
        : image.copyResize(
            oriented,
            height: oriented.height > 512 ? 512 : oriented.height,
          );
    return Uint8List.fromList(image.encodeJpg(preview, quality: 82));
  } on Object {
    return null;
  }
}

BookmarkVisualPage parsePixivBookmarkVisualPage(
  Map<String, dynamic> json, {
  required int expectedUserId,
  required BookmarkVisibility visibility,
}) {
  final works = <BookmarkVisualWork>[];
  final rawIllusts = json['illusts'];
  if (rawIllusts is! List) {
    throw const FormatException('Pixiv bookmark response omitted illusts');
  }

  for (final rawIllust in rawIllusts) {
    if (rawIllust is! Map) continue;
    final illust = Map<String, dynamic>.from(rawIllust);
    final illustId = _integer(illust['id']);
    if (illustId == null || illustId <= 0 || illust['visible'] == false) {
      continue;
    }

    final images = <BookmarkVisualImageReference>[];
    final rawMetaPages = illust['meta_pages'];
    if (rawMetaPages is List && rawMetaPages.isNotEmpty) {
      for (var pageIndex = 0; pageIndex < rawMetaPages.length; pageIndex++) {
        final rawMetaPage = rawMetaPages[pageIndex];
        if (rawMetaPage is! Map) continue;
        final imageUrls = rawMetaPage['image_urls'];
        final url = imageUrls is Map ? _trustedMediumUrl(imageUrls) : null;
        if (url != null) {
          images.add(
            BookmarkVisualImageReference(pageIndex: pageIndex, url: url),
          );
        }
      }
    } else {
      final imageUrls = illust['image_urls'];
      final url = imageUrls is Map ? _trustedMediumUrl(imageUrls) : null;
      if (url != null) {
        images.add(BookmarkVisualImageReference(pageIndex: 0, url: url));
      }
    }
    if (images.isNotEmpty) {
      works.add(BookmarkVisualWork(illustId: illustId, images: images));
    }
  }

  final nextOffset = _validatedNextOffset(
    json['next_url'],
    expectedUserId: expectedUserId,
    visibility: visibility,
  );
  return BookmarkVisualPage(works: works, nextOffset: nextOffset);
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is String) {
    final decoded = jsonDecode(value);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  }
  throw const FormatException('Pixiv returned an invalid bookmark response');
}

int? _integer(Object? value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '');
}

String? _trustedMediumUrl(Map<dynamic, dynamic> imageUrls) {
  for (final key in const <String>['medium', 'large']) {
    final value = imageUrls[key];
    if (value is! String || value.isEmpty) continue;
    final uri = Uri.tryParse(value);
    if (uri != null &&
        uri.scheme == 'https' &&
        uri.host.toLowerCase() == _pixivImageHost) {
      return value;
    }
  }
  return null;
}

int? _validatedNextOffset(
  Object? value, {
  required int expectedUserId,
  required BookmarkVisibility visibility,
}) {
  if (value == null || value == '') return null;
  if (value is! String) {
    throw const FormatException('Pixiv returned an invalid next_url');
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.toLowerCase() != _pixivApiHost ||
      uri.path != _pixivBookmarkPath) {
    throw const FormatException('Refused an unexpected Pixiv next_url');
  }
  final nextUserId = int.tryParse(uri.queryParameters['user_id'] ?? '');
  final nextVisibility = uri.queryParameters['restrict'];
  final offset = int.tryParse(uri.queryParameters['offset'] ?? '');
  if ((nextUserId != null && nextUserId != expectedUserId) ||
      (nextVisibility != null && nextVisibility != visibility.name) ||
      offset == null ||
      offset < 0) {
    throw const FormatException('Pixiv next_url changed bookmark scope');
  }
  return offset;
}
