import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/er/prefer.dart';
import 'package:pixez/page/hello/ranking/rank_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Prefer.init();
  });

  test('persists selected ranking modes and personal bookmark tags', () async {
    final store = RankStore();

    await store.saveChange(
      <int, bool>{0: true, 1: false, 5: true},
      selectedTags: const <String>['Fate', 'Azur Lane', 'Fate'],
    );

    final restored = RankStore();
    await restored.init();

    expect(restored.modeList, <String>['day', 'week']);
    expect(restored.tagList, <String>['Azur Lane', 'Fate']);
  });

  test('reset clears both ranking mode and personal tag selections', () async {
    final store = RankStore();
    await store.saveChange(
      <int, bool>{0: true},
      selectedTags: const <String>['Fate'],
    );

    await store.reset();

    final restored = RankStore();
    await restored.init();
    expect(restored.modeList, isEmpty);
    expect(restored.tagList, isEmpty);
    expect(store.inChoice, isTrue);
  });
}
