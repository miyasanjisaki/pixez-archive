import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/iqdb_result_parser.dart';
import 'package:pixez/utils/reverse_image_search.dart';

void main() {
  test('parses mirror result URLs without inventing a Pixiv ID', () {
    const html = '''
      <div class="pages">
        <table>
          <tr><th>Best match</th></tr>
          <tr><td class="image">
            <a href="//danbooru.donmai.us/posts/12345678"><img></a>
          </td></tr>
          <tr><td>Danbooru 1200×1800 [92.4% similarity]</td></tr>
        </table>
      </div>
    ''';

    final result = parseIqdbResults(html);
    expect(result, hasLength(1));
    expect(result.single.providerId, 'iqdb');
    expect(result.single.illustId, isNull);
    expect(result.single.similarity, 92.4);
    expect(
      result.single.sourceUrl,
      'https://danbooru.donmai.us/posts/12345678',
    );
  });

  test('retains an explicit Pixiv result as a Pixiv candidate', () {
    const html = '''
      <div class="pages">
        <table>
          <tr><th>Possible match</th></tr>
          <tr><td class="image">
            <a href="https://www.pixiv.net/artworks/87654321"><img></a>
          </td></tr>
          <tr><td>Pixiv [64%]</td></tr>
        </table>
      </div>
    ''';

    final result = parseIqdbResults(html, probe: ReverseImageProbeKind.center);
    expect(result.single.illustId, 87654321);
    expect(result.single.probe, ReverseImageProbeKind.center);
  });

  test(
    'extracts only an explicitly labelled Pixiv ID from mirror metadata',
    () {
      const html = '''
      <div class="pages"><table>
        <tr><th>Best match</th></tr>
        <tr><td class="image">
          <a href="https://cdn.example/thumb.jpg"><img alt="Pixiv Id 19871999"></a>
          <a href="https://danbooru.donmai.us/posts/55555555">post</a>
        </td></tr>
        <tr><td>[88%]</td></tr>
      </table></div>
    ''';

      final result = parseIqdbResults(html).single;
      expect(result.illustId, 19871999);
      expect(result.sourceUrl, 'https://danbooru.donmai.us/posts/55555555');
    },
  );

  test('ignores no-match tables and internal IQDB links', () {
    const html = '''
      <div class="pages">
        <table class="nomatch"><tr><th>No relevant matches</th></tr></table>
        <table>
          <tr><th>Best match</th></tr>
          <tr><td class="image"><a href="https://safe.iqdb.org/foo">x</a></td></tr>
          <tr><td>[99%]</td></tr>
        </table>
      </div>
    ''';
    expect(parseIqdbResults(html), isEmpty);
  });

  test('filters very weak generic guesses', () {
    const html = '''
      <div class="pages"><table>
        <tr><th>Possible match</th></tr>
        <tr><td class="image">
          <a href="https://danbooru.donmai.us/posts/12">post</a>
        </td></tr>
        <tr><td>[44.9%]</td></tr>
      </table></div>
    ''';
    expect(parseIqdbResults(html), isEmpty);
  });

  test('does not infer Pixiv identity from an unrelated thumbnail name', () {
    const html = '''
      <div class="pages"><table>
        <tr><th>Best match</th></tr>
        <tr><td class="image">
          <a href="https://cdn.example/12345678_p0.jpg"><img></a>
          <a href="https://danbooru.donmai.us/posts/91">post</a>
        </td></tr>
        <tr><td>[96%]</td></tr>
      </table></div>
    ''';
    final result = parseIqdbResults(html).single;
    expect(result.illustId, isNull);
    expect(result.sourceUrl, contains('danbooru'));
  });

  test('classifies a service queue/error page separately from no result', () {
    expect(
      () => parseIqdbResults("<div class='err'>Can't read query result!</div>"),
      throwsA(isA<IqdbResponseException>()),
    );
    expect(
      () => parseIqdbResults(
        '<title>Just a moment...</title>'
        '<script src="/cdn-cgi/challenge-platform/main.js"></script>',
      ),
      throwsA(
        isA<IqdbResponseException>().having(
          (error) => error.message,
          'message',
          contains('browser verification'),
        ),
      ),
    );
  });
}
