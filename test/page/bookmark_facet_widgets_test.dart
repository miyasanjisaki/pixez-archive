import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/models/bookmark_library_query.dart';
import 'package:pixez/page/user/bookmark/bookmark_facet_widgets.dart';

void main() {
  const tags = <BookmarkTagFacet>[
    BookmarkTagFacet(name: '初音ミク', translatedName: 'Hatsune Miku', count: 42),
    BookmarkTagFacet(name: 'VOCALOID', count: 30),
    BookmarkTagFacet(name: '風景', count: 3),
  ];

  testWidgets('tag row toggles a tag and keeps a picked tag visible', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => BookmarkTagChipsRow(
              tags: tags,
              selectedTag: selected,
              maximumChips: 2,
              onSelected: (tag) => setState(() => selected = tag),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('#初音ミク'), findsOneWidget);
    expect(find.textContaining('#風景'), findsNothing);
    await tester.tap(find.textContaining('#初音ミク'));
    await tester.pump();
    expect(selected, '初音ミク');
    await tester.tap(find.textContaining('#初音ミク'));
    await tester.pump();
    expect(selected, isNull);

    // Pick a tag outside the top chips from the full list.
    await tester.tap(find.byIcon(Icons.sell_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('風景'));
    await tester.pumpAndSettle();
    expect(selected, '風景');
    expect(find.textContaining('#風景'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('artist picker filters by name and returns the artist', (
    tester,
  ) async {
    BookmarkArtistFacet? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await showBookmarkArtistPicker(context, const [
                  BookmarkArtistFacet(id: 10, name: 'Alice', count: 5),
                  BookmarkArtistFacet(id: 20, name: 'Bob', count: 2),
                ]);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'bo');
    await tester.pump();
    expect(find.text('Alice'), findsNothing);
    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();
    expect(picked?.id, 20);
    expect(tester.takeException(), isNull);
  });
}
