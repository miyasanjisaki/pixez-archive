/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 *
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pixez/er/prefer.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/lighting/lighting_page.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/illust.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/page/search/result_illust_store.dart';
import 'package:pixez/page/search/suggest/search_suggestion_page.dart';
import 'package:pixez/utils/illust_result_options.dart';

enum UgoiraFilter {
  all,
  onlyUgoira,
  noUgoira,
}

class ResultIllustList extends StatefulWidget {
  final String word;

  const ResultIllustList({Key? key, required this.word}) : super(key: key);

  @override
  _ResultIllustListState createState() => _ResultIllustListState();
}

class _ResultIllustListState extends State<ResultIllustList> {
  late ResultIllustStore resultIllustStore;
  late ApiForceSource futureGet;
  late ScrollController _scrollController;
  late StreamSubscription<String> listen;
  final sort = [
    "date_desc",
    "date_asc",
    "popular_desc",
    "popular_male_desc",
    "popular_female_desc"
  ];
  static List<String> search_target = [
    "partial_match_for_tags",
    "exact_match_for_tags",
    "title_and_caption"
  ];
  String searchTarget = search_target[0];
  String selectSort = "date_desc";
  int searchAIType = 0;
  UgoiraFilter ugoiraFilter = UgoiraFilter.all;
  IllustResultSort loadedResultSort = IllustResultSort.apiOrder;
  IllustContentFilter contentFilter = IllustContentFilter.all;
  int selectStarNum = 0;
  List<int> starNum = [
    0,
    100,
    250,
    500,
    1000,
    5000,
    7500,
    10000,
    20000,
    30000,
    50000,
  ];
  List<List<int>> premiumStarNum = [
    [],
    [10000],
    [50000, 99999],
    [10000, 49999],
    [5000, 9999],
    [1000, 4999],
    [500, 999],
    [300, 499],
    [100, 299],
    [50, 99],
    [30, 49],
    [10, 29],
  ];
  List<int> _bookmarkNumList = [];
  bool recordRememberCurrentSelection = false;
  bool inited = false;

  bool get _usesOfficialPopularPreview =>
      selectSort == 'popular_desc' && accountStore.now?.isPremium != 1;

  bool get _usesExpandedPopularPreview =>
      _usesOfficialPopularPreview && _dateTimeRange == null;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    checkInit();
    listen = topStore.topStream.listen((event) {
      if (event == "401" && _scrollController.hasClients) {
        _scrollController.position.jumpTo(0);
      }
    });
  }

  checkInit() async {
    final prefix = 'illust_search_result_';
    final searchAIKey = '${prefix}_search_ai_type';
    final searchTargetKey = '${prefix}_search_target';
    final searchSortKey = '${prefix}_search_sort';
    final ugoiraFilterKey = '${prefix}_ugoira_filter';
    final loadedResultSortKey = '${prefix}_loaded_result_sort';
    final contentFilterKey = '${prefix}_content_filter';
    final recordRememberCurrentSelectionKey =
        'illust_search_result_record_remember_current_selection';
    recordRememberCurrentSelection =
        Prefer.getBool(recordRememberCurrentSelectionKey) ?? false;
    if (!mounted) return;
    setState(() {
      if (recordRememberCurrentSelection) {
        searchTarget = Prefer.getString(searchTargetKey) ?? search_target[0];
        selectSort = Prefer.getString(searchSortKey) ?? "date_desc";
        if (accountStore.now?.isPremium != 1 &&
            (selectSort == 'popular_male_desc' ||
                selectSort == 'popular_female_desc')) {
          selectSort = 'popular_desc';
        }
        searchAIType = Prefer.getInt(searchAIKey) ?? 0;
        ugoiraFilter = _enumValueOr(
          UgoiraFilter.values,
          Prefer.getInt(ugoiraFilterKey),
          UgoiraFilter.all,
        );
        loadedResultSort = _enumValueOr(
          IllustResultSort.values,
          Prefer.getInt(loadedResultSortKey),
          IllustResultSort.apiOrder,
        );
        contentFilter = _enumValueOr(
          IllustContentFilter.values,
          Prefer.getInt(contentFilterKey),
          IllustContentFilter.all,
        );
      }
      _changeQueryParams();
      inited = true;
    });
  }

  record() async {
    final prefix = 'illust_search_result_';
    final searchAIKey = '${prefix}_search_ai_type';
    final searchTargetKey = '${prefix}_search_target';
    final searchSortKey = '${prefix}_search_sort';
    final ugoiraFilterKey = '${prefix}_ugoira_filter';
    final loadedResultSortKey = '${prefix}_loaded_result_sort';
    final contentFilterKey = '${prefix}_content_filter';
    await Prefer.setString(searchTargetKey, searchTarget);
    await Prefer.setString(searchSortKey, selectSort);
    await Prefer.setInt(searchAIKey, searchAIType);
    await Prefer.setInt(ugoiraFilterKey, ugoiraFilter.index);
    await Prefer.setInt(loadedResultSortKey, loadedResultSort.index);
    await Prefer.setInt(contentFilterKey, contentFilter.index);
  }

  T _enumValueOr<T>(List<T> values, int? index, T fallback) {
    if (index == null || index < 0 || index >= values.length) return fallback;
    return values[index];
  }

  @override
  void dispose() {
    listen.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _buildSearchToolbar(context),
        if (_hasActiveResultOptions) _buildActiveResultOptions(context),
        if (_usesOfficialPopularPreview) _buildPopularPreviewNotice(context),
        Expanded(
          child: !inited
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(
                  top: false,
                  child: LightingList(
                    source: futureGet,
                    scrollController: _scrollController,
                    filter: _hasContentFilter ? _matchesContentFilter : null,
                    comparator: buildIllustResultComparator<Illusts>(
                      loadedResultSort,
                      bookmarksOf: (illust) => illust.totalBookmarks,
                      viewsOf: (illust) => illust.totalView,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildPopularPreviewNotice(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.local_fire_department_outlined,
                  color: colorScheme.onSecondaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(I18n.of(context).popular_preview_expanded,
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      _usesExpandedPopularPreview
                          ? I18n.of(context).popular_preview_expanded_hint
                          : I18n.of(context).popular_preview_single_hint,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchToolbar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: colorScheme.surfaceContainerHigh,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.65),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => SearchSuggestionPage(
                        preword: widget.word,
                      ),
                    ),
                  );
                },
                child: SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Icon(
                          Icons.search,
                          size: 20,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.word,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: I18n.of(context).date_duration,
            isSelected: _dateTimeRange != null,
            selectedIcon: const Icon(Icons.date_range),
            icon: const Icon(Icons.date_range_outlined),
            onPressed: () => _buildShowDateRange(context),
          ),
          if (accountStore.now?.isPremium == 1) _buildPremiumStar(),
          _buildStar(),
          Badge(
            isLabelVisible: _activeSheetFilterCount > 0,
            label: Text('$_activeSheetFilterCount'),
            child: IconButton.filledTonal(
              tooltip: I18n.of(context).filter,
              onPressed: () => _buildShowBottomSheet(context),
              icon: const Icon(Icons.tune),
            ),
          ),
        ],
      ),
    );
  }

  bool get _hasActiveResultOptions =>
      loadedResultSort != IllustResultSort.apiOrder ||
      contentFilter != IllustContentFilter.all ||
      ugoiraFilter != UgoiraFilter.all;

  int get _activeSheetFilterCount {
    var count = 0;
    if (searchTarget != search_target[0]) count++;
    if (selectSort != sort[0]) count++;
    if (searchAIType != 0) count++;
    if (ugoiraFilter != UgoiraFilter.all) count++;
    if (loadedResultSort != IllustResultSort.apiOrder) count++;
    if (contentFilter != IllustContentFilter.all) count++;
    return count;
  }

  Widget _buildActiveResultOptions(BuildContext context) {
    final chips = <Widget>[
      if (loadedResultSort != IllustResultSort.apiOrder)
        ActionChip(
          avatar: const Icon(Icons.leaderboard_outlined, size: 18),
          label: Text(_loadedResultSortLabel(context)),
          onPressed: () => _buildShowBottomSheet(context),
        ),
      if (contentFilter != IllustContentFilter.all)
        ActionChip(
          avatar: const Icon(Icons.collections_outlined, size: 18),
          label: Text(_contentFilterLabel(context)),
          onPressed: () => _buildShowBottomSheet(context),
        ),
      if (ugoiraFilter != UgoiraFilter.all)
        ActionChip(
          avatar: const Icon(Icons.animation, size: 18),
          label: Text(_ugoiraFilterLabel(context)),
          onPressed: () => _buildShowBottomSheet(context),
        ),
    ];
    return Semantics(
      label: I18n.of(context).active_filters,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Row(
          children: [
            for (var index = 0; index < chips.length; index++) ...[
              if (index > 0) const SizedBox(width: 8),
              chips[index],
            ],
          ],
        ),
      ),
    );
  }

  String _loadedResultSortLabel(BuildContext context) {
    return switch (loadedResultSort) {
      IllustResultSort.apiOrder => I18n.of(context).default_title,
      IllustResultSort.bookmarksDesc =>
        '${I18n.of(context).total_bookmark} ↓',
      IllustResultSort.viewsDesc => '${I18n.of(context).total_view} ↓',
    };
  }

  String _contentFilterLabel(BuildContext context) {
    return switch (contentFilter) {
      IllustContentFilter.all => I18n.of(context).all,
      IllustContentFilter.illustration => I18n.of(context).illust,
      IllustContentFilter.manga => I18n.of(context).manga,
    };
  }

  String _ugoiraFilterLabel(BuildContext context) {
    return switch (ugoiraFilter) {
      UgoiraFilter.all => I18n.of(context).all,
      UgoiraFilter.onlyUgoira => I18n.of(context).ugoira_only,
      UgoiraFilter.noUgoira => I18n.of(context).ugoira_none,
    };
  }

  bool get _hasContentFilter => contentFilter != IllustContentFilter.all ||
      ugoiraFilter != UgoiraFilter.all;

  bool _matchesContentFilter(Illusts illust) {
    final matchesUgoira = switch (ugoiraFilter) {
      UgoiraFilter.all => true,
      UgoiraFilter.onlyUgoira => illust.type == 'ugoira',
      UgoiraFilter.noUgoira => illust.type != 'ugoira',
    };
    return matchesUgoira && matchesIllustContent(illust.type, contentFilter);
  }

  DateTimeRange? _dateTimeRange;

  Future _buildShowDateRange(BuildContext context) async {
    DateTimeRange? dateTimeRange = await showDateRangePicker(
        context: context,
        initialDateRange: _dateTimeRange,
        firstDate: DateTime(2007, 8),
        lastDate: DateTime.now());
    if (dateTimeRange != null) {
      _dateTimeRange = dateTimeRange;
      setState(() {
        _changeQueryParams();
      });
    }
  }

  _changeQueryParams() {
    final keyword = _starValue == 0
        ? widget.word
        : '${widget.word} ${_starValue}users入り';
    if (_usesOfficialPopularPreview) {
      final searchAiType =
          searchAIType == 1 || muteStore.banAIIllust ? 1 : searchAIType;
      futureGet = ApiForceSource(
        futureGet: (bool force) => _usesExpandedPopularPreview
            ? apiClient.getExpandedPopularPreview(
                keyword,
                searchTarget: searchTarget,
                searchAiType: searchAiType,
              )
            : apiClient.getPopularPreview(
                keyword,
                searchTarget: searchTarget,
                searchAiType: searchAiType,
                startDate: _dateTimeRange?.start,
                endDate: _dateTimeRange?.end,
              ),
      );
      return;
    }
    if (_starValue == 0)
      futureGet = ApiForceSource(
          futureGet: (bool e) => apiClient.getSearchIllust(widget.word,
              search_target: searchTarget,
              sort: selectSort,
              start_date: _dateTimeRange?.start,
              end_date: _dateTimeRange?.end,
              bookmark_num: _bookmarkNumList,
              search_ai_type: searchAIType));
    else
      futureGet = ApiForceSource(
          futureGet: (bool e) => apiClient.getSearchIllust(
              '${widget.word} ${_starValue}users入り',
              search_target: searchTarget,
              sort: selectSort,
              start_date: _dateTimeRange?.start,
              end_date: _dateTimeRange?.end,
              bookmark_num: _bookmarkNumList,
              search_ai_type: searchAIType));
  }

  void _buildShowBottomSheet(BuildContext context) {
    final initialSearchAIType = searchAIType;
    final initialSearchTarget = searchTarget;
    final initialSelectSort = selectSort;
    var resultIllustSortWidget = ResultIllustSortWidget(
        searchAIType: searchAIType,
        selectSort: selectSort,
        searchTarget: searchTarget,
        ugoiraFilter: ugoiraFilter,
        loadedResultSort: loadedResultSort,
        contentFilter: contentFilter,
        onApply: () {
          final serverQueryChanged = initialSearchAIType != searchAIType ||
              initialSearchTarget != searchTarget ||
              initialSelectSort != selectSort;
          if (serverQueryChanged) {
            setState(() {
              _changeQueryParams();
            });
          }
        },
        onSateChange: (
            {required bool recordRememberCurrentSelection,
            required IllustContentFilter contentFilter,
            required IllustResultSort loadedResultSort,
            required int searchAIType,
            required String searchTarget,
            required String selectSort,
            required UgoiraFilter ugoiraFilter}) {
          setState(() {
            this.searchAIType = searchAIType;
            this.searchTarget = searchTarget;
            this.selectSort = selectSort;
            this.ugoiraFilter = ugoiraFilter;
            this.loadedResultSort = loadedResultSort;
            this.contentFilter = contentFilter;
            this.recordRememberCurrentSelection =
                recordRememberCurrentSelection;
          });
          if (recordRememberCurrentSelection) {
            record();
          }
        });
    // showDialog(context: context, builder: (context) => resultIllustSortWidget);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => resultIllustSortWidget,
    );
  }

  int _starValue = 0;

  Widget _buildPremiumStar() {
    return PopupMenuButton<List<int>>(
      initialValue: _bookmarkNumList,
      tooltip: I18n.of(context).total_bookmark,
      icon: Icon(
        Icons.format_list_numbered,
        color: _bookmarkNumList.isEmpty
            ? null
            : Theme.of(context).colorScheme.primary,
      ),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16.0))),
      itemBuilder: (context) {
        return premiumStarNum.map((List<int> value) {
          if (value.isEmpty) {
            return PopupMenuItem(
              value: value,
              child: Text(I18n.of(context).default_title),
              onTap: () {
                setState(() {
                  _bookmarkNumList = value;
                  _changeQueryParams();
                });
              },
            );
          } else {
            final minStr = value.elementAtOrNull(1) == null
                ? ">${value.elementAtOrNull(0) ?? ''}"
                : "${value.elementAtOrNull(0) ?? ''}";
            final maxStr = value.elementAtOrNull(1) == null
                ? ""
                : "〜${value.elementAtOrNull(1)}";

            return PopupMenuItem(
              value: value,
              child: Text("${minStr}${maxStr}"),
              onTap: () {
                setState(() {
                  _bookmarkNumList = value;
                  _changeQueryParams();
                });
              },
            );
          }
        }).toList();
      },
    );
  }

  Widget _buildStar() {
    return PopupMenuButton(
      initialValue: _starValue,
      tooltip: I18n.of(context).bookmark,
      icon: Icon(
        Icons.sort,
        color:
            _starValue == 0 ? null : Theme.of(context).colorScheme.primary,
      ),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16.0))),
      itemBuilder: (context) {
        return starNum.map((int value) {
          if (value > 0) {
            return PopupMenuItem(
              value: value,
              child: Text("${value} users入り"),
              onTap: () {
                setState(() {
                  _starValue = value;
                  _changeQueryParams();
                });
              },
            );
          } else {
            return PopupMenuItem(
              value: value,
              child: Text("Default"),
              onTap: () {
                setState(() {
                  _starValue = value;
                  _changeQueryParams();
                });
              },
            );
          }
        }).toList();
      },
    );
  }
}

class ResultIllustSortWidget extends StatefulWidget {
  final int searchAIType;
  final String selectSort;
  final String searchTarget;
  final UgoiraFilter ugoiraFilter;
  final IllustResultSort loadedResultSort;
  final IllustContentFilter contentFilter;
  final Function onApply;
  final Function(
      {required String searchTarget,
      required String selectSort,
      required int searchAIType,
      required UgoiraFilter ugoiraFilter,
      required IllustResultSort loadedResultSort,
      required IllustContentFilter contentFilter,
      required bool recordRememberCurrentSelection}) onSateChange;
  const ResultIllustSortWidget(
      {super.key,
      required this.searchAIType,
      required this.selectSort,
      required this.searchTarget,
      required this.ugoiraFilter,
      required this.loadedResultSort,
      required this.contentFilter,
      required this.onApply,
      required this.onSateChange});

  @override
  State<ResultIllustSortWidget> createState() => _ResultIllustSortWidgetState();
}

class _ResultIllustSortWidgetState extends State<ResultIllustSortWidget> {
  late int searchAIType = widget.searchAIType;
  late String selectSort = widget.selectSort;
  late String searchTarget = widget.searchTarget;
  late UgoiraFilter ugoiraFilter = widget.ugoiraFilter;
  late IllustResultSort loadedResultSort = widget.loadedResultSort;
  late IllustContentFilter contentFilter = widget.contentFilter;
  final sort = [
    "date_desc",
    "date_asc",
    "popular_desc",
    "popular_male_desc",
    "popular_female_desc"
  ];
  static List<String> search_target = [
    "partial_match_for_tags",
    "exact_match_for_tags",
    "title_and_caption"
  ];
  bool recordRememberCurrentSelection = false;
  final rememberKey = 'illust_search_result_record_remember_current_selection';
  @override
  void initState() {
    super.initState();
    initMethod();
  }

  initMethod() async {
    if (mounted) {
      setState(() {
        recordRememberCurrentSelection = Prefer.getBool(rememberKey) ?? false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPremium = accountStore.now?.isPremium == 1;
    final searchTargetMap = {
      0: I18n.of(context).partial_match_for_tag,
      1: I18n.of(context).exact_match_for_tag,
      2: I18n.of(context).title_and_caption,
    };
    final selectSortMap = {
      0: I18n.of(context).date_desc,
      1: I18n.of(context).date_asc,
      2: isPremium
          ? I18n.of(context).popular_desc
          : '${I18n.of(context).popular_desc} · ${I18n.of(context).popular_preview_short}',
      if (isPremium) ...{
        3: I18n.of(context).popular_male_desc,
        4: I18n.of(context).popular_female_desc,
      }
    };
    final loadedResultSortMap = {
      IllustResultSort.apiOrder: I18n.of(context).default_title,
      IllustResultSort.bookmarksDesc:
          '${I18n.of(context).total_bookmark} ↓',
      IllustResultSort.viewsDesc: '${I18n.of(context).total_view} ↓',
    };
    final contentFilterMap = {
      IllustContentFilter.all: I18n.of(context).all,
      IllustContentFilter.illustration: I18n.of(context).illust,
      IllustContentFilter.manga: I18n.of(context).manga,
    };
    final ugoiraFilterMap = {
      UgoiraFilter.all: I18n.of(context).all,
      UgoiraFilter.onlyUgoira: I18n.of(context).ugoira_only,
      UgoiraFilter.noUgoira: I18n.of(context).ugoira_none,
    };
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.88,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      I18n.of(context).filter,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(I18n.of(context).cancel),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.icon(
                    onPressed: () => _applyAndClose(context),
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(I18n.of(context).apply),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildSectionHeader(
                      context,
                      icon: Icons.manage_search,
                      label: I18n.of(context).search_matching,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                        children: [
                          for (final (index, data)
                              in searchTargetMap.entries.indexed)
                            _buildTargetItem(index, data, context),
                        ],
                      ),
                    ),
                    _buildSectionHeader(
                      context,
                      icon: Icons.swap_vert,
                      label: I18n.of(context).pixiv_sort,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                        children: [
                          for (final (index, data)
                              in selectSortMap.entries.indexed)
                            _buildSortItem(index, context, data),
                        ],
                      ),
                    ),
                    _buildChoiceRow(
                      context,
                      icon: Icons.leaderboard_outlined,
                      label: I18n.of(context).loaded_result_sort,
                      values: loadedResultSortMap,
                      selected: loadedResultSort,
                      onSelected: (value) {
                        setState(() {
                          loadedResultSort = value;
                        });
                      },
                    ),
                    _buildChoiceRow(
                      context,
                      icon: Icons.collections_outlined,
                      label: I18n.of(context).content_type,
                      values: contentFilterMap,
                      selected: contentFilter,
                      onSelected: (value) {
                        setState(() {
                          contentFilter = value;
                          if (value != IllustContentFilter.all) {
                            ugoiraFilter = UgoiraFilter.all;
                          }
                        });
                      },
                    ),
                    _buildChoiceRow(
                      context,
                      icon: Icons.animation,
                      label: I18n.of(context).ugoira_filter,
                      values: ugoiraFilterMap,
                      selected: ugoiraFilter,
                      onSelected: (value) {
                        setState(() {
                          ugoiraFilter = value;
                          if (value != UgoiraFilter.all) {
                            contentFilter = IllustContentFilter.all;
                          }
                        });
                      },
                    ),
                    SwitchListTile(
                      value: searchAIType != 1,
                      onChanged: (v) {
                        setState(() {
                          searchAIType = !v ? 1 : 0;
                        });
                      },
                      title: Text(I18n.of(context).ai_generated),
                    ),
                    SwitchListTile(
                      value: recordRememberCurrentSelection,
                      onChanged: (v) {
                        setState(() {
                          recordRememberCurrentSelection = v;
                        });
                      },
                      title:
                          Text(I18n.of(context).remember_current_selections),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _applyAndClose(BuildContext context) async {
    await Prefer.setBool(rememberKey, recordRememberCurrentSelection);
    if (!mounted || !context.mounted) return;
    widget.onSateChange(
      searchTarget: searchTarget,
      selectSort: selectSort,
      searchAIType: searchAIType,
      ugoiraFilter: ugoiraFilter,
      loadedResultSort: loadedResultSort,
      contentFilter: contentFilter,
      recordRememberCurrentSelection: recordRememberCurrentSelection,
    );
    widget.onApply();
    Navigator.of(context).pop();
  }

  Widget _buildChoiceRow<T>(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Map<T, String> values,
    required T selected,
    required ValueChanged<T> onSelected,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in values.entries)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: ChoiceChip(
                    label: Text(entry.value),
                    selected: selected == entry.key,
                    onSelected: (_) => onSelected(entry.key),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context, {
    required IconData icon,
    required String label,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSortItem(
      int _, BuildContext context, MapEntry<int, String> data) {
    final value = sort[data.key];
    final selected = selectSort == value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        selected: selected,
        selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(data.value),
        trailing: selected ? const Icon(Icons.check, size: 20) : null,
        onTap: () {
          setState(() {
            selectSort = value;
          });
        },
      ),
    );
  }

  Widget _buildTargetItem(
      int index, MapEntry<int, String> data, BuildContext context) {
    final selected = search_target.indexOf(searchTarget) == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        selected: selected,
        selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(data.value),
        trailing: selected ? const Icon(Icons.check, size: 20) : null,
        onTap: () {
          setState(() {
            searchTarget = search_target[index];
          });
        },
      ),
    );
  }
}
