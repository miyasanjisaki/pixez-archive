import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/saucenao_result_parser.dart';

void main() {
  test('chooses the highest-confidence visible Pixiv result', () {
    const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">95.00%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
      <div class="result hidden">
        <div class="resultsimilarityinfo">50.00%</div>
        <a href="https://www.pixiv.net/member_illust.php?illust_id=23456789">Pixiv</a>
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

  test('does not auto-open a medium-confidence candidate', () {
    const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">72.50%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
    ''';

    expect(parseSauceNaoPixivIds(html), isEmpty);
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
