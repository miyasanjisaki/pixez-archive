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

  test('builds a compact user-facing mode summary', () {
    expect(
      displayModeUserSummary(
        automatic: true,
        activeRefreshRate: 120.000007,
        chinese: true,
      ),
      '自动 · 当前 120 Hz',
    );
    expect(
      displayModeUserSummary(
        automatic: false,
        activeRefreshRate: null,
        selectedRefreshRate: 90,
        chinese: true,
      ),
      '固定 · 当前 90 Hz',
    );
    expect(
      displayModeUserSummary(automatic: true, activeRefreshRate: 120),
      'Automatic · current 120 Hz',
    );
  });

  test('advanced report only exposes allowlisted status fields', () {
    const nativeReport =
        'reason=settings target=120.00Hz native={sdk: 36, '
        'deviceModel: Secret Phone, requestedRefreshRate: 120.000007, '
        'surfaceAvailable: true, surfaceValid: true, '
        'surfaceFrameRateHintSubmitted: true, '
        'supportedModes: [1:1156x2510@120, 2:1156x2510@60]}';

    final report = buildSafeDisplayModeDiagnosticReport(
      automatic: true,
      activeRefreshRate: 120.000007,
      nativeDiagnostics: nativeReport,
      chinese: true,
    );

    expect(report, contains('当前刷新率：120 Hz'));
    expect(report, contains('请求刷新率：120 Hz'));
    expect(report, contains('显示表面：正常'));
    expect(report, contains('高刷请求：已提交'));
    expect(report, isNot(contains('Secret Phone')));
    expect(report, isNot(contains('sdk')));
    expect(report, isNot(contains('supportedModes')));
    expect(report, isNot(contains('1156x2510')));
  });
}
