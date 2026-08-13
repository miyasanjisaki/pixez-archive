import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/saucenao_result_parser.dart';

void main() {
  test('chooses the highest-confidence visible Pixiv result', () {
    const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">95.00%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
      <div class="result">
        <div class="resultsimilarityinfo">50.00%</div>
        <a href="https://www.pixiv.net/member_illust.php?illust_id=23456789">Pixiv</a>
      </div>
    ''';

    expect(parseSauceNaoPixivIds(html), [12345678]);
  });

  test('exact compatibility result exposes only the highest candidate', () {
    const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">91.00%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
      <div class="result">
        <div class="resultsimilarityinfo">89.00%</div>
        <a href="https://www.pixiv.net/artworks/23456789">Pixiv</a>
      </div>
    ''';

    expect(parseSauceNaoPixivIds(html), [12345678]);
  });

  test('ignores a higher non-Pixiv result and uses the Pixiv result', () {
    const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">99.00%</div>
        <a href="https://example.com/image/999">Other source</a>
      </div>
      <div class="result">
        <div class="resultsimilarityinfo">88.50%</div>
        <a href="https://www.pixiv.net/artworks/34567890">Pixiv</a>
      </div>
    ''';

    expect(parseSauceNaoPixivIds(html), [34567890]);
  });

  test('does not auto-open a low-similarity candidate', () {
    const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">41.20%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
    ''';

    expect(parseSauceNaoPixivIds(html), isEmpty);
  });

  test('returns a medium-confidence candidate for explicit confirmation', () {
    const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">72.50%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
    ''';

    final result = parseSauceNaoPixivResults(html);
    expect(result.exactMatches, isEmpty);
    expect(result.possibleMatches, hasLength(1));
    expect(result.possibleMatches.single.illustId, 12345678);
    expect(result.possibleMatches.single.similarity, 72.5);
  });

  test('keeps a folded medium-confidence candidate for confirmation', () {
    const html = '''
      <div class="result hidden">
        <div class="resultsimilarityinfo">72.50%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
      <div class="result hidden">
        <div class="resultsimilarityinfo">50.00%</div>
        <a href="https://www.pixiv.net/artworks/23456789">Pixiv</a>
      </div>
    ''';

    final result = parseSauceNaoPixivResults(html);
    expect(result.exactMatches, isEmpty);
    expect(result.possibleMatches.map((candidate) => candidate.illustId), [
      12345678,
    ]);
  });

  test('deduplicates a Pixiv work and keeps its best similarity', () {
    const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">64.00%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
      <div class="result">
        <div class="resultsimilarityinfo">83.00%</div>
        <a href="https://www.pixiv.net/member_illust.php?illust_id=12345678">Pixiv</a>
      </div>
    ''';

    final result = parseSauceNaoPixivResults(html);
    expect(result.exactMatches, hasLength(1));
    expect(result.exactMatches.single.similarity, 83);
    expect(result.possibleMatches, isEmpty);
  });

  test('all-database output only accepts explicit Pixiv links', () {
    const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">99.00%</div>
        <a href="https://danbooru.example/posts/12345678">12345678</a>
      </div>
      <div class="result">
        <div class="resultsimilarityinfo">79.00%</div>
        <a href="https://i.pximg.net/img-original/img/2026/01/02/03/04/05/23456789_p0.jpg">Pixiv image</a>
      </div>
    ''';

    final result = parseSauceNaoPixivResults(html);
    expect(result.exactMatches, isEmpty);
    expect(result.possibleMatches.map((candidate) => candidate.illustId), [
      23456789,
    ]);
  });

  test('reports a service limit page as an error', () {
    expect(
      () => parseSauceNaoPixivIds('<p>Daily limit exceeded</p>'),
      throwsA(isA<SauceNaoResponseException>()),
    );
    expect(
      () => parseSauceNaoPixivIds('<form>CAPTCHA verification required</form>'),
      throwsA(isA<SauceNaoResponseException>()),
    );
  });
}
