import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/page/user/bookmark/bookmark_search_page.dart';

void main() {
  testWidgets('pill search field fits a narrow app bar and clears', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = TextEditingController();
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: BookmarkSearchField(
              controller: controller,
              hintText: '搜索标题、作者、标签或 PID',
              clearTooltip: '清除',
              onChanged: changes.add,
              onSubmitted: changes.add,
            ),
            actions: [
              IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
            ],
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
    final box = tester.getSize(find.byType(BookmarkSearchField));
    expect(box.height, lessThanOrEqualTo(56));

    await tester.enterText(
      find.byType(TextField),
      'ミク very long query text that keeps going',
    );
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(changes.last, '');
  });
}
