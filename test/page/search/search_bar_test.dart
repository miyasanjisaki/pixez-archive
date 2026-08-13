import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/page/search/search_bar.dart' as pixez;
import 'package:pixez/src/generated/i18n/app_localizations.dart';

Widget _testApp({
  required VoidCallback onSearch,
  required VoidCallback onImageSearch,
  bool imageSearchBusy = false,
}) {
  return MaterialApp(
    locale: const Locale('en', 'US'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: pixez.SearchBar(
        onSearch: onSearch,
        onSaucenao: onImageSearch,
        imageSearchBusy: imageSearchBusy,
      ),
    ),
  );
}

void main() {
  testWidgets('search icon and hint area trigger text search', (tester) async {
    var searchCount = 0;
    var imageSearchCount = 0;
    await tester.pumpWidget(
      _testApp(
        onSearch: () => searchCount++,
        onImageSearch: () => imageSearchCount++,
      ),
    );

    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    expect(searchCount, 1);
    expect(imageSearchCount, 0);

    await tester.tap(find.byKey(const Key('text_search_action')));
    await tester.pump();
    expect(searchCount, 2);
    expect(imageSearchCount, 0);
  });

  testWidgets('reverse image search has an independent callback', (
    tester,
  ) async {
    var searchCount = 0;
    var imageSearchCount = 0;
    await tester.pumpWidget(
      _testApp(
        onSearch: () => searchCount++,
        onImageSearch: () => imageSearchCount++,
      ),
    );

    await tester.tap(find.byIcon(Icons.image_search_outlined));
    await tester.pump();

    expect(imageSearchCount, 1);
    expect(searchCount, 0);
  });

  testWidgets('primary search action is at least 48 logical pixels high', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(onSearch: () {}, onImageSearch: () {}));

    final size = tester.getSize(find.byKey(const Key('text_search_action')));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets(
    'reverse image search shows progress and prevents duplicate taps',
    (tester) async {
      var imageSearchCount = 0;
      await tester.pumpWidget(
        _testApp(
          onSearch: () {},
          onImageSearch: () => imageSearchCount++,
          imageSearchBusy: true,
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.image_search_outlined), findsNothing);
      await tester.tap(find.byType(CircularProgressIndicator));
      await tester.pump();
      expect(imageSearchCount, 0);
    },
  );
}
