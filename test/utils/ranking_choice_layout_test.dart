import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/ranking_choice_layout.dart';

void main() {
  test('portrait ranking chooser clears bottom navigation and safe area', () {
    expect(
      calculateRankingChoiceBottomPadding(
        viewportWidth: 1080,
        viewportHeight: 2400,
        systemBottomPadding: 24,
      ),
      104,
    );
  });

  test('landscape ranking chooser only keeps content and system padding', () {
    expect(
      calculateRankingChoiceBottomPadding(
        viewportWidth: 2400,
        viewportHeight: 1080,
        systemBottomPadding: 12,
      ),
      20,
    );
  });

  test('negative system padding is ignored defensively', () {
    expect(
      calculateRankingChoiceBottomPadding(
        viewportWidth: 1080,
        viewportHeight: 2400,
        systemBottomPadding: -1,
      ),
      rankingChoiceBottomNavigationClearance,
    );
  });
}
