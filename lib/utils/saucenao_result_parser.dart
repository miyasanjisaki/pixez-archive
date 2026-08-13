import 'package:html/parser.dart' show parse;
import 'package:pixez/utils/pixiv_image_identity.dart';

class SauceNaoResponseException implements Exception {
  final String message;

  const SauceNaoResponseException(this.message);

  @override
  String toString() => message;
}

class _PixivCandidate {
  final int illustId;
  final double similarity;

  const _PixivCandidate(this.illustId, this.similarity);
}

/// Parses SauceNAO result cards and returns only the highest-confidence Pixiv
/// work. Low-similarity cards are not auto-opened as if they were exact hits.
List<int> parseSauceNaoPixivIds(String html, {double minimumSimilarity = 80}) {
  _throwForServicePage(html);

  final document = parse(html);
  var blocks = document.querySelectorAll('.result');
  if (blocks.isEmpty) blocks = document.querySelectorAll('.resulttable');

  final candidates = <_PixivCandidate>[];
  for (final block in blocks) {
    if (block.classes.contains('hidden')) continue;
    final similarityText =
        block.querySelector('.resultsimilarityinfo')?.text ?? block.text;
    final similarityMatch = RegExp(
      r'([0-9]+(?:\.[0-9]+)?)\s*%',
    ).firstMatch(similarityText);
    final similarity = double.tryParse(similarityMatch?.group(1) ?? '');
    if (similarity == null || similarity < minimumSimilarity) continue;

    final ids = <int>[];
    for (final anchor in block.querySelectorAll('a[href]')) {
      ids.addAll(
        extractPixivIllustIdsFromText(anchor.attributes['href'] ?? ''),
      );
    }
    if (ids.isNotEmpty) candidates.add(_PixivCandidate(ids.first, similarity));
  }

  if (candidates.isEmpty) return const [];
  candidates.sort((a, b) => b.similarity.compareTo(a.similarity));
  return [candidates.first.illustId];
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
