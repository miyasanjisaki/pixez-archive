class DisplayModeValue {
  const DisplayModeValue({
    required this.id,
    required this.width,
    required this.height,
    required this.refreshRate,
  });

  final int id;
  final int width;
  final int height;
  final double refreshRate;
}

String formatRefreshRate(double refreshRate) {
  if (!refreshRate.isFinite || refreshRate <= 0) return '--';
  final rounded = refreshRate.round();
  if ((refreshRate - rounded).abs() <= displayModeRefreshRateTolerance) {
    return '$rounded';
  }
  return refreshRate.toStringAsFixed(1);
}

String displayModeUserSummary({
  required bool automatic,
  double? activeRefreshRate,
  double? selectedRefreshRate,
  bool chinese = false,
}) {
  final refreshRate =
      activeRefreshRate != null &&
          activeRefreshRate.isFinite &&
          activeRefreshRate > 0
      ? activeRefreshRate
      : selectedRefreshRate;
  final policy = automatic
      ? (chinese ? '自动' : 'Automatic')
      : (chinese ? '固定' : 'Fixed');
  if (refreshRate == null || !refreshRate.isFinite || refreshRate <= 0) {
    if (chinese) return automatic ? '自动 · 最高刷新率' : '固定显示模式';
    return automatic ? 'Automatic · highest refresh rate' : 'Fixed mode';
  }
  final current = chinese ? '当前' : 'current';
  return '$policy · $current ${formatRefreshRate(refreshRate)} Hz';
}

/// Builds the only display-mode diagnostic text that may be shown or copied.
///
/// The native report intentionally remains an implementation detail. This
/// function extracts a small allowlist and never forwards device identifiers,
/// SDK values, mode IDs, resolutions, supported-mode lists, or raw errors.
String buildSafeDisplayModeDiagnosticReport({
  required bool automatic,
  double? activeRefreshRate,
  String nativeDiagnostics = '',
  bool chinese = false,
}) {
  final requestedRefreshRate = _diagnosticNumber(
    nativeDiagnostics,
    const <String>['target', 'requestedRefreshRate'],
  );
  final surfaceAvailable = _diagnosticBool(
    nativeDiagnostics,
    'surfaceAvailable',
  );
  final surfaceValid = _diagnosticBool(nativeDiagnostics, 'surfaceValid');
  final frameRateHintSubmitted = _diagnosticBool(
    nativeDiagnostics,
    'surfaceFrameRateHintSubmitted',
  );

  final surfaceState = surfaceAvailable == true && surfaceValid == true
      ? (chinese ? '正常' : 'ready')
      : surfaceAvailable == false || surfaceValid == false
      ? (chinese ? '不可用' : 'unavailable')
      : (chinese ? '未知' : 'unknown');
  final requestState = frameRateHintSubmitted == true
      ? (chinese ? '已提交' : 'submitted')
      : frameRateHintSubmitted == false
      ? (chinese ? '未提交' : 'not submitted')
      : (chinese ? '未知' : 'unknown');
  final lines = chinese
      ? <String>[
          '显示策略：${automatic ? '自动（最高刷新率）' : '手动固定'}',
          '当前刷新率：${_diagnosticRate(activeRefreshRate, chinese: true)}',
          '请求刷新率：${_diagnosticRate(requestedRefreshRate, chinese: true)}',
          '显示表面：$surfaceState',
          '高刷请求：$requestState',
        ]
      : <String>[
          'Policy: ${automatic ? 'automatic (highest refresh rate)' : 'fixed'}',
          'Active refresh rate: ${_diagnosticRate(activeRefreshRate)}',
          'Requested refresh rate: ${_diagnosticRate(requestedRefreshRate)}',
          'Flutter surface: $surfaceState',
          'High-refresh request: $requestState',
        ];
  return lines.join('\n');
}

String _diagnosticRate(double? value, {bool chinese = false}) {
  if (value == null || !value.isFinite || value <= 0) {
    return chinese ? '未知' : 'unknown';
  }
  return '${formatRefreshRate(value)} Hz';
}

double? _diagnosticNumber(String report, List<String> keys) {
  for (final key in keys) {
    final match = RegExp(
      '(?:^|[\\s,{])${RegExp.escape(key)}(?:=|:\\s*)([0-9]+(?:\\.[0-9]+)?)',
    ).firstMatch(report);
    final value = double.tryParse(match?.group(1) ?? '');
    if (value != null && value.isFinite && value > 0) return value;
  }
  return null;
}

bool? _diagnosticBool(String report, String key) {
  final match = RegExp(
    '(?:^|[\\s,{])${RegExp.escape(key)}(?:=|:\\s*)(true|false)',
    caseSensitive: false,
  ).firstMatch(report);
  final value = match?.group(1)?.toLowerCase();
  if (value == 'true') return true;
  if (value == 'false') return false;
  return null;
}

const double displayModeRefreshRateTolerance = 0.05;

bool displayModeRefreshRatesMatch(double left, double right) {
  return (left - right).abs() <= displayModeRefreshRateTolerance;
}

DisplayModeValue? highestRefreshModeForResolution(
  Iterable<DisplayModeValue> modes, {
  required int width,
  required int height,
}) {
  DisplayModeValue? selected;
  for (final mode in modes) {
    if (mode.id == 0 || mode.width != width || mode.height != height) continue;
    if (selected == null || mode.refreshRate > selected.refreshRate) {
      selected = mode;
    }
  }
  if (selected == null) {
    for (final mode in modes) {
      if (mode.id == 0) continue;
      if (selected == null || mode.refreshRate > selected.refreshRate) {
        selected = mode;
      }
    }
  }
  return selected;
}

DisplayModeValue? restoreDisplayMode(
  Iterable<DisplayModeValue> modes, {
  required int? id,
  required int? width,
  required int? height,
  required double? refreshRate,
}) {
  final candidates = modes.where((mode) => mode.id != 0).toList();
  if (candidates.isEmpty) return null;

  if (id != null) {
    for (final mode in candidates) {
      if (mode.id == id &&
          (width == null || height == null || refreshRate == null)) {
        return mode;
      }
      final savedRefreshRate = refreshRate;
      if (mode.id == id &&
          width != null &&
          height != null &&
          savedRefreshRate != null &&
          mode.width == width &&
          mode.height == height &&
          displayModeRefreshRatesMatch(mode.refreshRate, savedRefreshRate)) {
        return mode;
      }
    }
  }

  if (width != null && height != null && refreshRate != null) {
    for (final mode in candidates) {
      if (mode.width == width &&
          mode.height == height &&
          displayModeRefreshRatesMatch(mode.refreshRate, refreshRate)) {
        return mode;
      }
    }
  }

  return null;
}

DisplayModeValue? migrateLegacyDisplayMode(
  List<DisplayModeValue> modes,
  int legacyIndex,
) {
  // flutter_displaymode exposes an artificial Auto entry at supported[0].
  // The old settings page persisted modes[index - 1], i.e. this exact list
  // position rather than a stable mode identity.
  if (legacyIndex < 0 || legacyIndex >= modes.length) return null;
  final legacyMode = modes[legacyIndex];
  if (legacyMode.id == 0) return null;

  // The old preference stored a position in a device-provided list. During
  // migration, keep its resolution but select the highest rate so a stale
  // 60 Hz position cannot keep an upgraded install capped indefinitely.
  return highestRefreshModeForResolution(
        modes,
        width: legacyMode.width,
        height: legacyMode.height,
      ) ??
      legacyMode;
}
