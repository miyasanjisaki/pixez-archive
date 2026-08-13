import 'package:html/parser.dart' show parse;
import 'package:pixez/utils/pixiv_image_identity.dart';

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

  const SauceNaoPixivCandidate({
    required this.illustId,
    required this.similarity,
    required this.pixivUrl,
  });
}

class SauceNaoPixivResults {
  final List<SauceNaoPixivCandidate> exactMatches;
  final List<SauceNaoPixivCandidate> possibleMatches;

  const SauceNaoPixivResults({
    required this.exactMatches,
    required this.possibleMatches,
  });

  bool get isEmpty => exactMatches.isEmpty && possibleMatches.isEmpty;
}

/// Parses SauceNAO result cards into auto-openable and confirmable Pixiv
/// candidates. A candidate is accepted only when SauceNAO returned an explicit
/// Pixiv/pximg link; an unrelated database result containing a bare number is
/// never treated as a Pixiv illustration.
SauceNaoPixivResults parseSauceNaoPixivResults(
  String html, {
  double exactSimilarity = 80,
  double possibleSimilarity = 60,
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
  for (final block in blocks) {
    final similarityText =
        block.querySelector('.resultsimilarityinfo')?.text ?? block.text;
    final similarityMatch = RegExp(
      r'([0-9]+(?:\.[0-9]+)?)\s*%',
    ).firstMatch(similarityText);
    final similarity = double.tryParse(similarityMatch?.group(1) ?? '');
    if (similarity == null || similarity < possibleSimilarity) continue;

    for (final anchor in block.querySelectorAll('a[href]')) {
      final url = anchor.attributes['href'] ?? '';
      if (!_isExplicitPixivUrl(url)) continue;
      final ids = extractPixivIllustIdsFromText(url);
      for (final illustId in ids) {
        final candidate = SauceNaoPixivCandidate(
          illustId: illustId,
          similarity: similarity,
          pixivUrl: url,
        );
        final previous = bestById[illustId];
        if (previous == null || previous.similarity < similarity) {
          bestById[illustId] = candidate;
        }
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
  );
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

void _throwForServicePage(String html) {
  final lower = html.toLowerCase();
  const markers = <String, String>{
    'captcha': 'SauceNAO requires verification',
    'verify you are human': 'SauceNAO requires verification',
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
