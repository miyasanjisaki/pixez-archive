import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/utils/display_mode_selection.dart';

const modes = <DisplayModeValue>[
  DisplayModeValue(id: 0, width: 0, height: 0, refreshRate: 0),
  DisplayModeValue(id: 1, width: 1080, height: 2400, refreshRate: 60),
  DisplayModeValue(id: 2, width: 1080, height: 2400, refreshRate: 120),
  DisplayModeValue(id: 3, width: 1440, height: 3200, refreshRate: 60),
  DisplayModeValue(id: 4, width: 1440, height: 3200, refreshRate: 119.96),
];

void main() {
  test('selects the highest refresh rate without changing resolution', () {
    final selected = highestRefreshModeForResolution(
      modes,
      width: 1080,
      height: 2400,
    );

    expect(selected?.id, 2);
  });

  test(
    'falls back to the highest enumerated mode when active size is unknown',
    () {
      final selected = highestRefreshModeForResolution(
        modes,
        width: 0,
        height: 0,
      );

      expect(selected?.id, 2);
    },
  );

  test('restores by stable signature when a mode id changes', () {
    final selected = restoreDisplayMode(
      modes,
      id: 99,
      width: 1440,
      height: 3200,
      refreshRate: 120,
    );

    expect(selected?.id, 4);
  });

  test('legacy 60 Hz index migrates to highest rate at its resolution', () {
    final selected = migrateLegacyDisplayMode(modes, 1);

    expect(selected?.id, 2);
  });

  test('automatic legacy mode remains automatic', () {
    expect(migrateLegacyDisplayMode(modes, 0), isNull);
  });

  test('does not trust a reused mode id with a different signature', () {
    final selected = restoreDisplayMode(
      modes,
      id: 2,
      width: 1440,
      height: 3200,
      refreshRate: 60,
    );

    expect(selected?.id, 3);
  });

  test('can restore old id-only preference when signature is absent', () {
    final selected = restoreDisplayMode(
      modes,
      id: 2,
      width: null,
      height: null,
      refreshRate: null,
    );

    expect(selected?.id, 2);
  });

  test('invalid legacy index falls back to automatic policy', () {
    expect(migrateLegacyDisplayMode(modes, 99), isNull);
  });
}
