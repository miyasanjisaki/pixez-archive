/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 */

/// Describes one official Pixiv popular-preview request.
///
/// The key and label identify the request in merge diagnostics.
class PopularPreviewWindow {
  const PopularPreviewWindow({required this.key, required this.label});

  final String key;
  final String label;
}

const PopularPreviewWindow popularPreviewOverallWindow = PopularPreviewWindow(
  key: 'overall',
  label: 'Overall',
);
const PopularPreviewWindow popularPreviewLast30DaysWindow =
    PopularPreviewWindow(key: 'last_30_days', label: 'Last 30 days');
const PopularPreviewWindow popularPreviewDays31To180Window =
    PopularPreviewWindow(key: 'days_31_to_180', label: 'Days 31-180');
const PopularPreviewWindow popularPreviewDays181To365Window =
    PopularPreviewWindow(key: 'days_181_to_365', label: 'Days 181-365');
const PopularPreviewWindow popularPreviewDays366PlusWindow =
    PopularPreviewWindow(key: 'days_366_plus', label: 'More than 365 days ago');

/// Stable precedence used when the official single-page previews are merged.
const List<PopularPreviewWindow> expandedPopularPreviewWindowOrder = [
  popularPreviewOverallWindow,
  popularPreviewLast30DaysWindow,
  popularPreviewDays31To180Window,
  popularPreviewDays181To365Window,
  popularPreviewDays366PlusWindow,
];

class PopularPreviewRequestWindow {
  const PopularPreviewRequestWindow({
    required this.window,
    this.startDate,
    this.endDate,
  });

  final PopularPreviewWindow window;
  final DateTime? startDate;
  final DateTime? endDate;
}

/// Builds adjacent calendar ranges plus Pixiv's undated overall preview.
List<PopularPreviewRequestWindow> buildExpandedPopularPreviewWindows(
  DateTime now,
) {
  // These are calendar-only API values. UTC keeps subtraction stable across
  // daylight-saving transitions while preserving the caller's local date.
  final today = DateTime.utc(now.year, now.month, now.day);
  final last30Start = today.subtract(const Duration(days: 29));
  final days31To180Start = today.subtract(const Duration(days: 179));
  final days181To365Start = today.subtract(const Duration(days: 364));

  return List.unmodifiable([
    const PopularPreviewRequestWindow(window: popularPreviewOverallWindow),
    PopularPreviewRequestWindow(
      window: popularPreviewLast30DaysWindow,
      startDate: last30Start,
      endDate: today,
    ),
    PopularPreviewRequestWindow(
      window: popularPreviewDays31To180Window,
      startDate: days31To180Start,
      endDate: last30Start.subtract(const Duration(days: 1)),
    ),
    PopularPreviewRequestWindow(
      window: popularPreviewDays181To365Window,
      startDate: days181To365Start,
      endDate: days31To180Start.subtract(const Duration(days: 1)),
    ),
    PopularPreviewRequestWindow(
      window: popularPreviewDays366PlusWindow,
      startDate: DateTime.utc(2007, 9, 1),
      endDate: days181To365Start.subtract(const Duration(days: 1)),
    ),
  ]);
}

class PopularPreviewWindowResult {
  const PopularPreviewWindowResult._({
    required this.window,
    this.responseData,
    this.error,
  });

  factory PopularPreviewWindowResult.success(
    PopularPreviewWindow window,
    Map<String, dynamic> responseData,
  ) {
    return PopularPreviewWindowResult._(
      window: window,
      responseData: responseData,
    );
  }

  factory PopularPreviewWindowResult.failure(
    PopularPreviewWindow window,
    Object error,
  ) {
    return PopularPreviewWindowResult._(window: window, error: error);
  }

  final PopularPreviewWindow window;
  final Map<String, dynamic>? responseData;
  final Object? error;
}

class PopularPreviewWindowSummary {
  const PopularPreviewWindowSummary({
    required this.window,
    required this.succeeded,
    required this.rawCount,
    required this.addedCount,
    this.errorType,
  });

  final PopularPreviewWindow window;
  final bool succeeded;
  final int rawCount;
  final int addedCount;
  final String? errorType;

  int get duplicateCount => rawCount - addedCount;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': window.key,
    'label': window.label,
    'succeeded': succeeded,
    'raw_count': rawCount,
    'added_count': addedCount,
    'duplicate_count': duplicateCount,
    if (errorType != null) 'error_type': errorType,
  };
}

class PopularPreviewMergeResult {
  const PopularPreviewMergeResult({
    required this.illusts,
    required this.windowSummaries,
    required this.rawCount,
    required this.baseResponseData,
  });

  final List<Map<String, dynamic>> illusts;
  final List<PopularPreviewWindowSummary> windowSummaries;
  final int rawCount;
  final Map<String, dynamic>? baseResponseData;

  int get uniqueCount => illusts.length;
  int get successfulWindowCount =>
      windowSummaries.where((summary) => summary.succeeded).length;
  int get failedWindowCount =>
      windowSummaries.where((summary) => !summary.succeeded).length;

  /// Builds a normal popular-preview shaped response with extra diagnostics.
  ///
  /// `next_url` is always null: the merged items are candidates from several
  /// independent official single-page previews. They are not a complete global
  /// ranking and must not be presented as ranks following the first preview.
  Map<String, dynamic> toResponseData() {
    final result = <String, dynamic>{...?baseResponseData};
    result['illusts'] = illusts;
    result['next_url'] = null;
    result['popular_preview_merge'] = <String, dynamic>{
      'complete_global_ranking': false,
      'raw_count': rawCount,
      'unique_count': uniqueCount,
      'successful_count': successfulWindowCount,
      'failed_count': failedWindowCount,
      'windows': windowSummaries.map((summary) => summary.toJson()).toList(),
    };
    return result;
  }
}

/// Merges official popular-preview payloads in canonical window order.
///
/// Duplicate illustration IDs retain the first occurrence. The function does
/// not sort by bookmark/view counts because doing so would falsely imply that
/// the server returned a complete global ranking.
PopularPreviewMergeResult mergePopularPreviewResponses(
  Iterable<PopularPreviewWindowResult> results,
) {
  final resultByKey = <String, PopularPreviewWindowResult>{};
  for (final result in results) {
    resultByKey.putIfAbsent(result.window.key, () => result);
  }

  final mergedIllusts = <Map<String, dynamic>>[];
  final seenIds = <String>{};
  final summaries = <PopularPreviewWindowSummary>[];
  Map<String, dynamic>? baseResponseData;
  var rawCount = 0;

  for (final window in expandedPopularPreviewWindowOrder) {
    final result = resultByKey[window.key];
    if (result == null) continue;

    final responseData = result.responseData;
    if (result.error != null || responseData == null) {
      summaries.add(
        PopularPreviewWindowSummary(
          window: window,
          succeeded: false,
          rawCount: 0,
          addedCount: 0,
          errorType: result.error?.runtimeType.toString() ?? 'MissingResponse',
        ),
      );
      continue;
    }

    final rawIllusts = responseData['illusts'];
    if (rawIllusts is! List || rawIllusts.any((item) => item is! Map)) {
      summaries.add(
        PopularPreviewWindowSummary(
          window: window,
          succeeded: false,
          rawCount: 0,
          addedCount: 0,
          errorType: 'FormatException',
        ),
      );
      continue;
    }

    baseResponseData ??= Map<String, dynamic>.from(responseData);
    rawCount += rawIllusts.length;
    var addedCount = 0;
    for (final rawIllust in rawIllusts) {
      final illust = Map<String, dynamic>.from(rawIllust as Map);
      final id = illust['id'];
      if (id != null && !seenIds.add(_normaliseIllustId(id))) continue;
      mergedIllusts.add(illust);
      addedCount++;
    }
    summaries.add(
      PopularPreviewWindowSummary(
        window: window,
        succeeded: true,
        rawCount: rawIllusts.length,
        addedCount: addedCount,
      ),
    );
  }

  return PopularPreviewMergeResult(
    illusts: List.unmodifiable(mergedIllusts),
    windowSummaries: List.unmodifiable(summaries),
    rawCount: rawCount,
    baseResponseData: baseResponseData,
  );
}

String _normaliseIllustId(Object id) {
  if (id is int) return id.toString();
  if (id is num && id.isFinite && id == id.truncateToDouble()) {
    return id.toInt().toString();
  }
  return id.toString();
}
