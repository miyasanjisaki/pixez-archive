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

  test('normalizes a provider-relative Pixiv result thumbnail', () {
    const html = '''
      <div class="result">
        <div class="resultimage">
          <img src="data:image/gif;base64,placeholder"
               data-src="/user_images/thumbs/12345678.jpg">
        </div>
        <div class="resultsimilarityinfo">72.50%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
    ''';

    final candidate = parseSauceNaoPixivResults(html).possibleMatches.single;
    expect(
      candidate.thumbnailUrl,
      'https://saucenao.com/user_images/thumbs/12345678.jpg',
    );
  });

  test('normalizes a protocol-relative generic result thumbnail', () {
    const html = '''
      <div class="result">
        <div class="resultimage">
          <img src="//cdn.saucenao.com/thumbs/result.jpg">
        </div>
        <div class="resultsimilarityinfo">76.00%</div>
        <a href="https://gelbooru.com/index.php?page=post&amp;s=view&amp;id=44">
          Gelbooru source
        </a>
      </div>
    ''';

    final candidate = parseSauceNaoPixivResults(html).externalMatches.single;
    expect(
      candidate.thumbnailUrl,
      'https://cdn.saucenao.com/thumbs/result.jpg',
    );
  });

  test('keeps a usable thumbnail while deduplicating to the best result', () {
    const html = '''
      <div class="result">
        <div class="resultimage"><img src="/thumbs/12345678.jpg"></div>
        <div class="resultsimilarityinfo">64.00%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
      <div class="result">
        <div class="resultsimilarityinfo">83.00%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
    ''';

    final candidate = parseSauceNaoPixivResults(html).exactMatches.single;
    expect(candidate.similarity, 83);
    expect(candidate.thumbnailUrl, 'https://saucenao.com/thumbs/12345678.jpg');
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
      23456789,
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
    expect(result.externalMatches.single.sourceUrl, contains('danbooru'));
    expect(result.externalMatches.single.similarity, 99);
  });

  test('retains a generic source result instead of inventing a Pixiv ID', () {
    const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">76.00%</div>
        <a href="https://gelbooru.com/index.php?page=post&amp;s=view&amp;id=44">
          Gelbooru source
        </a>
      </div>
    ''';

    final result = parseSauceNaoPixivResults(html);
    expect(result.exactMatches, isEmpty);
    expect(result.possibleMatches, isEmpty);
    expect(result.externalMatches, hasLength(1));
    expect(result.externalMatches.single.title, 'Gelbooru source');
  });

  test(
    'filters a weak generic source but retains an explicit weak Pixiv ID',
    () {
      const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">39.00%</div>
        <a href="https://example.com/posts/44">weak mirror</a>
      </div>
      <div class="result">
        <div class="resultsimilarityinfo">38.00%</div>
        <strong>Pixiv ID:</strong> 19871999
      </div>
    ''';

      final result = parseSauceNaoPixivResults(html);
      expect(result.externalMatches, isEmpty);
      expect(result.possibleMatches.single.illustId, 19871999);
    },
  );

  test('does not promote an unrelated canonical-looking filename to Pixiv', () {
    const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">96.00%</div>
        <a href="https://example.com/posts/44">mirror</a>
        <img src="https://example.com/files/12345678_p0.jpg">
      </div>
    ''';

    final result = parseSauceNaoPixivResults(html);
    expect(result.exactMatches, isEmpty);
    expect(result.possibleMatches, isEmpty);
    expect(result.externalMatches.single.sourceUrl, contains('example.com'));
  });

  test('rejects a non-network thumbnail URL', () {
    const html = '''
      <div class="result">
        <div class="resultimage"><img src="data:image/png;base64,AAAA"></div>
        <div class="resultsimilarityinfo">81.00%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
    ''';

    final candidate = parseSauceNaoPixivResults(html).exactMatches.single;
    expect(candidate.thumbnailUrl, isNull);
  });

  test('rejects insecure and off-provider thumbnail URLs', () {
    const html = '''
      <div class="result">
        <div class="resultimage">
          <img src="http://saucenao.com/thumbs/12345678.jpg">
        </div>
        <div class="resultsimilarityinfo">82.00%</div>
        <a href="https://www.pixiv.net/artworks/12345678">Pixiv</a>
      </div>
      <div class="result">
        <div class="resultimage">
          <img src="https://tracker.example/thumbs/23456789.jpg">
        </div>
        <div class="resultsimilarityinfo">81.00%</div>
        <a href="https://www.pixiv.net/artworks/23456789">Pixiv</a>
      </div>
    ''';

    expect(
      parseSauceNaoPixivResults(
        html,
      ).exactMatches.map((candidate) => candidate.thumbnailUrl),
      everyElement(isNull),
    );
  });

  test('accepts an explicitly labelled Pixiv ID on a mirror card', () {
    const html = '''
      <div class="result">
        <div class="resultsimilarityinfo">77.00%</div>
        <strong>Pixiv ID:</strong> 19871999
        <a href="https://danbooru.donmai.us/posts/55">mirror</a>
      </div>
    ''';

    final result = parseSauceNaoPixivResults(html);
    expect(result.possibleMatches.single.illustId, 19871999);
    expect(result.externalMatches, isEmpty);
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
    expect(
      () => parseSauceNaoPixivIds(
        '<title>Just a moment...</title>'
        '<p>Enable JavaScript and cookies to continue</p>'
        '<script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js">'
        '</script>',
      ),
      throwsA(
        isA<SauceNaoResponseException>().having(
          (error) => error.message,
          'message',
          contains('browser verification'),
        ),
      ),
    );
  });
}
