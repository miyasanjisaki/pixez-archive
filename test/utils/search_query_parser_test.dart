import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/search_query_parser.dart';

void main() {
  group('parseSearchQueryTerms', () {
    test('ignores leading, repeated, and trailing whitespace', () {
      expect(
        parseSearchQueryTerms('  first   second  '),
        ['first', 'second'],
      );
    });

    test('handles non-space whitespace and whitespace-only input', () {
      expect(parseSearchQueryTerms('\tfirst\nsecond\r\n'), ['first', 'second']);
      expect(parseSearchQueryTerms(' \t\n '), isEmpty);
    });
  });
}
