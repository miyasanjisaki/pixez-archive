const double rankingChoiceContentPadding = 8.0;

// The Material home page draws its bottom navigation over the page body.
// Keep the final row of ranking tags scrollable above that navigation bar.
const double rankingChoiceBottomNavigationClearance = 80.0;

double calculateRankingChoiceBottomPadding({
  required double viewportWidth,
  required double viewportHeight,
  required double systemBottomPadding,
}) {
  final safeBottom = systemBottomPadding < 0 ? 0.0 : systemBottomPadding;
  final usesBottomNavigation = viewportWidth <= viewportHeight;
  return safeBottom +
      (usesBottomNavigation
          ? rankingChoiceBottomNavigationClearance
          : rankingChoiceContentPadding);
}
