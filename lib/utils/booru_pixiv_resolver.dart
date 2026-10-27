import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:pixez/utils/pixiv_image_identity.dart';
import 'package:pixez/utils/reverse_image_search.dart';

/// Booru sites whose public post API exposes the original Pixiv source.
enum BooruSite { danbooru, yandere, konachan }

/// A single post on a supported booru, parsed from a search-result URL.
class BooruPostRef {
  final BooruSite site;
  final int postId;

  const BooruPostRef(this.site, this.postId);

  /// Read-only JSON endpoint for this post. None of these require login.
  Uri get apiUri => switch (site) {
    BooruSite.danbooru => Uri.https(
      'danbooru.donmai.us',
      '/posts/$postId.json',
      const <String, String>{'only': 'id,pixiv_id,source'},
    ),
    BooruSite.yandere => Uri.https('yande.re', '/post.json', <String, String>{
      'tags': 'id:$postId',
    }),
    BooruSite.konachan => Uri.https(
      'konachan.com',
      '/post.json',
      <String, String>{'tags': 'id:$postId'},
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is BooruPostRef && other.site == site && other.postId == postId;

  @override
  int get hashCode => Object.hash(site, postId);
}

final RegExp _postPathId = RegExp(r'^/posts?(?:/show)?/([1-9][0-9]{0,11})');

/// Recognises post pages such as `https://danbooru.donmai.us/posts/123`,
/// `https://yande.re/post/show/123` and `https://konachan.com/post/show/123`.
BooruPostRef? parseBooruPostUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final site = switch (host) {
    'danbooru.donmai.us' || 'safebooru.donmai.us' => BooruSite.danbooru,
    'yande.re' => BooruSite.yandere,
    'konachan.com' || 'konachan.net' => BooruSite.konachan,
    _ => null,
  };
  if (site == null) return null;
  final match = _postPathId.firstMatch(uri.path);
  final id = int.tryParse(match?.group(1) ?? '');
  return id == null ? null : BooruPostRef(site, id);
}

/// Extracts a Pixiv illustration ID from one booru API response.
///
/// Danbooru stores a dedicated `pixiv_id`; Moebooru sites (yande.re,
/// Konachan) only keep the `source` URL. A source is trusted only when it
/// points to pixiv.net or pximg.net, so a Twitter status number can never be
/// mistaken for a Pixiv work.
int? extractPixivIdFromBooruJson(Object? json) {
  Object? post = json;
  if (post is String) {
    try {
      post = jsonDecode(post);
    } on FormatException {
      return null;
    }
  }
  if (post is List) post = post.isEmpty ? null : post.first;
  if (post is! Map) return null;

  final pixivId = post['pixiv_id'];
  final directId = pixivId is int ? pixivId : int.tryParse('${pixivId ?? ''}');
  if (directId != null && directId > 0) return directId;

  final source = post['source'];
  if (source is! String || source.isEmpty) return null;
  final host = Uri.tryParse(source.trim())?.host.toLowerCase() ?? '';
  final isPixivHost =
      host == 'pixiv.net' ||
      host.endsWith('.pixiv.net') ||
      host == 'pximg.net' ||
      host.endsWith('.pximg.net');
  if (!isPixivHost) return null;
  final ids = extractPixivIllustIdsFromText(source);
  return ids.isEmpty ? null : ids.first;
}

typedef BooruJsonFetcher =
    Future<Object?> Function(Uri uri, CancelToken cancelToken);

/// Turns booru hits returned by IQDB/SauceNAO into Pixiv candidates.
///
/// IQDB never indexes Pixiv directly: a correct match usually arrives as a
/// Danbooru/yande.re post whose `source` is the Pixiv original. Without this
/// step the user saw a browser link instead of the Pixiv work.
class BooruPixivResolver {
  final BooruJsonFetcher fetchJson;
  final int maximumLookups;
  final double minimumSimilarity;
  final Duration timeout;
  final Map<BooruPostRef, int?> _cache = <BooruPostRef, int?>{};

  BooruPixivResolver({
    required this.fetchJson,
    this.maximumLookups = 6,
    this.minimumSimilarity = 50,
    this.timeout = const Duration(seconds: 10),
  });

  /// Creates a resolver backed by a small dedicated Dio client.
  factory BooruPixivResolver.network({Dio? dio}) {
    final client =
        dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 8),
            followRedirects: false,
            responseType: ResponseType.json,
            headers: const <String, String>{
              'User-Agent':
                  'PixEzArchive/1.0 (+https://github.com/miyasanjisaki/pixez-archive)',
              'Accept': 'application/json',
            },
          ),
        );
    return BooruPixivResolver(
      fetchJson: (uri, cancelToken) async {
        final response = await client.getUri<Object?>(
          uri,
          cancelToken: cancelToken,
        );
        return response.data;
      },
    );
  }

  /// Returns [hits] with `illustId` filled for every booru post that could be
  /// traced to Pixiv. Lookup failures leave the hit unchanged.
  Future<List<ReverseImageProviderHit>> resolve(
    List<ReverseImageProviderHit> hits, {
    CancelToken? cancelToken,
  }) async {
    final refs = <BooruPostRef>[];
    final ordered = hits.toList()
      ..sort((a, b) => b.similarity.compareTo(a.similarity));
    for (final hit in ordered) {
      if (hit.illustId != null || hit.similarity < minimumSimilarity) continue;
      final ref = parseBooruPostUrl(hit.sourceUrl);
      if (ref == null || refs.contains(ref)) continue;
      refs.add(ref);
      if (refs.length >= maximumLookups) break;
    }
    if (refs.isEmpty) return hits;

    final token = CancelToken();
    void forwardCancel() {
      if (!token.isCancelled) token.cancel('Booru lookup cancelled');
    }

    unawaited(cancelToken?.whenCancel.then((_) => forwardCancel()));
    try {
      await Future.wait(
        refs.map((ref) async {
          if (_cache.containsKey(ref)) return;
          try {
            final json = await fetchJson(ref.apiUri, token).timeout(timeout);
            _cache[ref] = extractPixivIdFromBooruJson(json);
          } on Object {
            // Do not cache failures: a later probe may succeed.
          }
        }),
      ).timeout(timeout + const Duration(seconds: 1));
    } on TimeoutException {
      forwardCancel();
    }

    return hits
        .map((hit) {
          if (hit.illustId != null) return hit;
          final ref = parseBooruPostUrl(hit.sourceUrl);
          final id = ref == null ? null : _cache[ref];
          return id == null ? hit : hit.withIllustId(id);
        })
        .toList(growable: false);
  }
}
