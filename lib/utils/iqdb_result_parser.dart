import 'package:html/dom.dart' show Element;
import 'package:html/parser.dart' show parse;
import 'package:pixez/utils/pixiv_image_identity.dart';
import 'package:pixez/utils/reverse_image_search.dart';

final Uri _iqdbOrigin = Uri.parse('https://safe.iqdb.org/');

class IqdbResponseException implements Exception {
  final String message;

  const IqdbResponseException(this.message);

  @override
  String toString() => message;
}

/// Parses the result cards returned by IQDB's documented public upload form.
/// IQDB indexes mirror/booru sites rather than Pixiv itself, so most hits are
/// intentionally retained as source-page URLs with a nullable Pixiv ID.
List<ReverseImageProviderHit> parseIqdbResults(
  String html, {
  ReverseImageProbeKind probe = ReverseImageProbeKind.full,
  double minimumSimilarity = 35,
}) {
  _throwForIqdbServicePage(html);
  final document = parse(html);
  final hits = <ReverseImageProviderHit>[];

  for (final table in document.querySelectorAll('.pages table')) {
    final text = table.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final lower = text.toLowerCase();
    if (lower.contains('no relevant matches') ||
        lower.contains('no match') ||
        lower.contains('your image')) {
      continue;
    }
    final similarityMatch = RegExp(
      r'([0-9]+(?:\.[0-9]+)?)\s*%',
    ).firstMatch(text);
    final similarity = double.tryParse(similarityMatch?.group(1) ?? '');
    if (similarity == null || similarity < minimumSimilarity) continue;

    final sourceUrls = <String>[];
    final imageAnchor = table.querySelector('td.image a[href]');
    final anchors = [
      if (imageAnchor != null) imageAnchor,
      ...table.querySelectorAll('a[href]'),
    ];
    for (final anchor in anchors) {
      final resolved = _normalizeExternalUrl(anchor.attributes['href'] ?? '');
      if (resolved == null) continue;
      if (!sourceUrls.contains(resolved)) sourceUrls.add(resolved);
    }
    String? sourceUrl;
    for (final url in sourceUrls) {
      if (!_looksLikeDirectImage(url)) {
        sourceUrl = url;
        break;
      }
    }
    if (sourceUrl == null && sourceUrls.isNotEmpty) {
      sourceUrl = sourceUrls.first;
    }
    if (sourceUrl == null) continue;

    final labelledIdentityText = StringBuffer(text);
    for (final image in table.querySelectorAll('img')) {
      labelledIdentityText
        ..write('\n')
        ..write(image.attributes['alt'] ?? '')
        ..write('\n')
        ..write(image.attributes['title'] ?? '');
    }
    final illustId = _isExplicitPixivUrl(sourceUrl)
        ? extractPixivIllustId(hints: <String?>[sourceUrl])
        : _extractLabelledPixivId(labelledIdentityText.toString());
    if (illustId == null && similarity < 45) continue;
    final thumbnailUrl = _extractThumbnailUrl(table);
    hits.add(
      ReverseImageProviderHit(
        providerId: 'iqdb',
        probe: probe,
        illustId: illustId,
        similarity: similarity,
        sourceUrl: sourceUrl,
        title: table.querySelector('th')?.text.trim(),
        thumbnailUrl: thumbnailUrl,
      ),
    );
  }

  final bestByUrl = <String, ReverseImageProviderHit>{};
  for (final hit in hits) {
    final previous = bestByUrl[hit.sourceUrl];
    if (previous == null || previous.similarity < hit.similarity) {
      bestByUrl[hit.sourceUrl] = hit;
    }
  }
  return bestByUrl.values.toList(growable: false)
    ..sort((a, b) => b.similarity.compareTo(a.similarity));
}

String? _extractThumbnailUrl(Element table) {
  final resultImages = table.querySelectorAll('td.image img');
  final images = resultImages.isNotEmpty
      ? resultImages
      : table.querySelectorAll('img');
  for (final image in images) {
    for (final attribute in const <String>[
      'data-original',
      'data-src',
      'src',
    ]) {
      final normalized = _normalizeProviderAssetUrl(
        image.attributes[attribute] ?? '',
        _iqdbOrigin,
      );
      if (normalized != null) return normalized;
    }
  }
  return null;
}

String? _normalizeProviderAssetUrl(String value, Uri providerOrigin) {
  final decoded = value.replaceAll('&amp;', '&').trim();
  if (decoded.isEmpty || decoded.startsWith('#')) return null;

  final parsed = Uri.tryParse(decoded);
  if (parsed == null) return null;
  final resolved = decoded.startsWith('//')
      ? Uri.tryParse('${providerOrigin.scheme}:$decoded')
      : parsed.hasScheme
      ? parsed
      : providerOrigin.resolveUri(parsed);
  final host = resolved?.host.toLowerCase() ?? '';
  if (resolved == null ||
      resolved.scheme.toLowerCase() != 'https' ||
      resolved.userInfo.isNotEmpty ||
      (resolved.hasPort && resolved.port != 443) ||
      !(host == 'iqdb.org' || host.endsWith('.iqdb.org'))) {
    return null;
  }
  return resolved.toString();
}

bool _isExplicitPixivUrl(String value) {
  final host = Uri.tryParse(value)?.host.toLowerCase() ?? '';
  return host == 'pixiv.net' ||
      host.endsWith('.pixiv.net') ||
      host == 'pximg.net' ||
      host.endsWith('.pximg.net');
}

int? _extractLabelledPixivId(String value) {
  final match = RegExp(
    r'(?:pixiv[\s_-]*(?:illust(?:ration)?[\s_-]*)?(?:id)?|'
    r'illust[\s_-]*id)\s*[:#=_-]?\s*([0-9]{5,12})',
    caseSensitive: false,
  ).firstMatch(value);
  final id = int.tryParse(match?.group(1) ?? '');
  return id != null && id > 0 ? id : null;
}

String? _normalizeExternalUrl(String value) {
  final decoded = value.replaceAll('&amp;', '&').trim();
  if (decoded.isEmpty || decoded.startsWith('#')) return null;
  final absolute = decoded.startsWith('//') ? 'https:$decoded' : decoded;
  final uri = Uri.tryParse(absolute);
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty || host == 'safe.iqdb.org' || host.endsWith('.iqdb.org')) {
    return null;
  }
  return uri.toString();
}

bool _looksLikeDirectImage(String value) {
  final path = Uri.tryParse(value)?.path.toLowerCase() ?? '';
  return RegExp(r'\.(?:jpe?g|png|gif|webp|avif)$').hasMatch(path);
}

void _throwForIqdbServicePage(String html) {
  final lower = html.toLowerCase();
  const markers = <String, String>{
    "can't read query result": 'IQDB server could not complete this search',
    'file too large': 'IQDB image exceeds the 8 MB limit',
    'unsupported image': 'IQDB does not support this image',
    'temporarily unavailable': 'IQDB is temporarily unavailable',
    'just a moment': 'IQDB browser verification is required',
    'enable javascript and cookies': 'IQDB browser verification is required',
    'cdn-cgi/challenge': 'IQDB browser verification is required',
    'cf-chl-': 'IQDB browser verification is required',
    'captcha': 'IQDB requires verification',
    'too many requests': 'IQDB rate limit reached',
  };
  for (final entry in markers.entries) {
    if (lower.contains(entry.key)) throw IqdbResponseException(entry.value);
  }
}
