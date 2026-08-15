import 'package:html/dom.dart' show Element;
import 'package:html/parser.dart' show parse;
import 'package:pixez/utils/pixiv_image_identity.dart';

final Uri _sauceNaoOrigin = Uri.parse('https://saucenao.com/');

class SauceNaoResponseException implements Exception {
  final String message;

  const SauceNaoResponseException(this.message);

  @override
  String toString() => message;
}

class SauceNaoPixivCandidate {
  final int illustId;
  final double similarity;
  final String pixivUrl;
  final String? thumbnailUrl;

  const SauceNaoPixivCandidate({
    required this.illustId,
    required this.similarity,
    required this.pixivUrl,
    this.thumbnailUrl,
  });
}

class SauceNaoExternalCandidate {
  final double similarity;
  final String sourceUrl;
  final String? title;
  final String? thumbnailUrl;

  const SauceNaoExternalCandidate({
    required this.similarity,
    required this.sourceUrl,
    this.title,
    this.thumbnailUrl,
  });
}

class SauceNaoPixivResults {
  final List<SauceNaoPixivCandidate> exactMatches;
  final List<SauceNaoPixivCandidate> possibleMatches;
  final List<SauceNaoExternalCandidate> externalMatches;

  const SauceNaoPixivResults({
    required this.exactMatches,
    required this.possibleMatches,
    this.externalMatches = const [],
  });

  bool get isEmpty =>
      exactMatches.isEmpty &&
      possibleMatches.isEmpty &&
      externalMatches.isEmpty;
}

/// Parses SauceNAO result cards into auto-openable and confirmable Pixiv
/// candidates. A candidate is accepted only when SauceNAO returned an explicit
/// Pixiv/pximg link; an unrelated database result containing a bare number is
/// never treated as a Pixiv illustration.
SauceNaoPixivResults parseSauceNaoPixivResults(
  String html, {
  double exactSimilarity = 80,
  double possibleSimilarity = 35,
}) {
  if (possibleSimilarity > exactSimilarity) {
    throw ArgumentError.value(
      possibleSimilarity,
      'possibleSimilarity',
      'must not be greater than exactSimilarity',
    );
  }
  _throwForServicePage(html);

  final document = parse(html);
  var blocks = document.querySelectorAll('.result');
  if (blocks.isEmpty) blocks = document.querySelectorAll('.resulttable');

  final bestById = <int, SauceNaoPixivCandidate>{};
  final bestExternalByUrl = <String, SauceNaoExternalCandidate>{};
  for (final block in blocks) {
    final similarityText =
        block.querySelector('.resultsimilarityinfo')?.text ?? block.text;
    final similarityMatch = RegExp(
      r'([0-9]+(?:\.[0-9]+)?)\s*%',
    ).firstMatch(similarityText);
    final similarity = double.tryParse(similarityMatch?.group(1) ?? '');
    if (similarity == null || similarity < possibleSimilarity) continue;
    final thumbnailUrl = _extractThumbnailUrl(block);

    var foundExplicitPixiv = false;
    for (final anchor in block.querySelectorAll('a[href]')) {
      final url = anchor.attributes['href'] ?? '';
      if (!_isExplicitPixivUrl(url)) continue;
      final ids = extractPixivIllustIdsFromText(url);
      if (ids.isEmpty) continue;
      foundExplicitPixiv = true;
      for (final illustId in ids) {
        final candidate = SauceNaoPixivCandidate(
          illustId: illustId,
          similarity: similarity,
          pixivUrl: url,
          thumbnailUrl: thumbnailUrl,
        );
        final previous = bestById[illustId];
        if (previous == null || previous.similarity < similarity) {
          bestById[illustId] = _withPreviousPixivThumbnail(candidate, previous);
        } else if (previous.thumbnailUrl == null && thumbnailUrl != null) {
          bestById[illustId] = SauceNaoPixivCandidate(
            illustId: previous.illustId,
            similarity: previous.similarity,
            pixivUrl: previous.pixivUrl,
            thumbnailUrl: thumbnailUrl,
          );
        }
      }
    }
    if (!foundExplicitPixiv) {
      final labelledIds = _extractLabelledPixivIds(block.text);
      for (final illustId in labelledIds) {
        foundExplicitPixiv = true;
        final candidate = SauceNaoPixivCandidate(
          illustId: illustId,
          similarity: similarity,
          pixivUrl: 'https://www.pixiv.net/artworks/$illustId',
          thumbnailUrl: thumbnailUrl,
        );
        final previous = bestById[illustId];
        if (previous == null || previous.similarity < similarity) {
          bestById[illustId] = _withPreviousPixivThumbnail(candidate, previous);
        } else if (previous.thumbnailUrl == null && thumbnailUrl != null) {
          bestById[illustId] = SauceNaoPixivCandidate(
            illustId: previous.illustId,
            similarity: previous.similarity,
            pixivUrl: previous.pixivUrl,
            thumbnailUrl: thumbnailUrl,
          );
        }
      }
    }
    if (!foundExplicitPixiv && similarity >= 45) {
      for (final anchor in block.querySelectorAll('a[href]')) {
        final url = _normalizeExternalResultUrl(
          anchor.attributes['href'] ?? '',
        );
        if (url == null) continue;
        final candidate = SauceNaoExternalCandidate(
          similarity: similarity,
          sourceUrl: url,
          title: anchor.text.trim().isEmpty ? null : anchor.text.trim(),
          thumbnailUrl: thumbnailUrl,
        );
        final previous = bestExternalByUrl[url];
        if (previous == null || previous.similarity < similarity) {
          bestExternalByUrl[url] = _withPreviousExternalThumbnail(
            candidate,
            previous,
          );
        } else if (previous.thumbnailUrl == null && thumbnailUrl != null) {
          bestExternalByUrl[url] = SauceNaoExternalCandidate(
            similarity: previous.similarity,
            sourceUrl: previous.sourceUrl,
            title: previous.title,
            thumbnailUrl: thumbnailUrl,
          );
        }
        break;
      }
    }
  }

  final candidates = bestById.values.toList()
    ..sort((a, b) => b.similarity.compareTo(a.similarity));
  return SauceNaoPixivResults(
    exactMatches: candidates
        .where((candidate) => candidate.similarity >= exactSimilarity)
        .toList(growable: false),
    possibleMatches: candidates
        .where(
          (candidate) =>
              candidate.similarity >= possibleSimilarity &&
              candidate.similarity < exactSimilarity,
        )
        .toList(growable: false),
    externalMatches:
        (bestExternalByUrl.values.toList()
              ..sort((a, b) => b.similarity.compareTo(a.similarity)))
            .toList(growable: false),
  );
}

SauceNaoPixivCandidate _withPreviousPixivThumbnail(
  SauceNaoPixivCandidate candidate,
  SauceNaoPixivCandidate? previous,
) {
  if (candidate.thumbnailUrl != null || previous?.thumbnailUrl == null) {
    return candidate;
  }
  return SauceNaoPixivCandidate(
    illustId: candidate.illustId,
    similarity: candidate.similarity,
    pixivUrl: candidate.pixivUrl,
    thumbnailUrl: previous!.thumbnailUrl,
  );
}

SauceNaoExternalCandidate _withPreviousExternalThumbnail(
  SauceNaoExternalCandidate candidate,
  SauceNaoExternalCandidate? previous,
) {
  if (candidate.thumbnailUrl != null || previous?.thumbnailUrl == null) {
    return candidate;
  }
  return SauceNaoExternalCandidate(
    similarity: candidate.similarity,
    sourceUrl: candidate.sourceUrl,
    title: candidate.title,
    thumbnailUrl: previous!.thumbnailUrl,
  );
}

String? _extractThumbnailUrl(Element block) {
  final resultImages = block.querySelectorAll('.resultimage img');
  final images = resultImages.isNotEmpty
      ? resultImages
      : block.querySelectorAll('img');
  for (final image in images) {
    for (final attribute in const <String>[
      'data-src',
      'data-original',
      'src',
    ]) {
      final normalized = _normalizeProviderAssetUrl(
        image.attributes[attribute] ?? '',
        _sauceNaoOrigin,
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
      !(host == 'saucenao.com' || host.endsWith('.saucenao.com'))) {
    return null;
  }
  return resolved.toString();
}

List<int> _extractLabelledPixivIds(String value) {
  final ids = <int>{};
  final pattern = RegExp(
    r'(?:pixiv[\s_-]*(?:illust(?:ration)?[\s_-]*)?(?:id)?|'
    r'illust[\s_-]*id)\s*[:#=_-]?\s*([0-9]{5,12})',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(value)) {
    final id = int.tryParse(match.group(1) ?? '');
    if (id != null && id > 0) ids.add(id);
  }
  return ids.toList(growable: false);
}

/// Compatibility wrapper for call sites that only want exact matches.
List<int> parseSauceNaoPixivIds(String html, {double minimumSimilarity = 80}) {
  return parseSauceNaoPixivResults(
        html,
        exactSimilarity: minimumSimilarity,
        possibleSimilarity: minimumSimilarity,
      ).exactMatches
      .take(1)
      .map((candidate) => candidate.illustId)
      .toList(growable: false);
}

bool _isExplicitPixivUrl(String value) {
  final decoded = value.replaceAll('&amp;', '&');
  final uri = Uri.tryParse(decoded);
  final host = uri?.host.toLowerCase() ?? '';
  return host == 'pixiv.net' ||
      host.endsWith('.pixiv.net') ||
      host == 'pximg.net' ||
      host.endsWith('.pximg.net');
}

String? _normalizeExternalResultUrl(String value) {
  final decoded = value.replaceAll('&amp;', '&').trim();
  if (decoded.isEmpty || decoded.startsWith('#')) return null;
  final absolute = decoded.startsWith('//') ? 'https:$decoded' : decoded;
  final uri = Uri.tryParse(absolute);
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty ||
      host == 'saucenao.com' ||
      host.endsWith('.saucenao.com')) {
    return null;
  }
  return uri.toString();
}

void _throwForServicePage(String html) {
  final lower = html.toLowerCase();
  const markers = <String, String>{
    'captcha': 'SauceNAO requires verification',
    'verify you are human': 'SauceNAO requires verification',
    'just a moment': 'SauceNAO browser verification is required',
    'enable javascript and cookies':
        'SauceNAO browser verification is required',
    'cdn-cgi/challenge': 'SauceNAO browser verification is required',
    'cf-chl-': 'SauceNAO browser verification is required',
    'daily limit exceeded': 'SauceNAO daily search limit reached',
    'exceeded your daily limit': 'SauceNAO daily search limit reached',
    'search limit exceeded': 'SauceNAO search limit reached',
    'too many requests': 'SauceNAO rate limit reached',
    'temporarily unavailable': 'SauceNAO is temporarily unavailable',
    'maintenance mode': 'SauceNAO is under maintenance',
  };
  for (final entry in markers.entries) {
    if (lower.contains(entry.key)) throw SauceNaoResponseException(entry.value);
  }
}
