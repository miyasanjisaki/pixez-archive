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
