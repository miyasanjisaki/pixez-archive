import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:pixez/lighting/lighting_page.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/models/bookmark_library.dart';
import 'package:pixez/page/user/bookmark/bookmark_search_controller.dart';

/// Search inside the signed-in user's own illustration/manga bookmarks.
class BookmarkSearchPage extends StatefulWidget {
  final int userId;

  const BookmarkSearchPage({super.key, required this.userId});

  static Route<void> route(int userId) => MaterialPageRoute<void>(
    builder: (_) => BookmarkSearchPage(userId: userId),
  );

  @override
  State<BookmarkSearchPage> createState() => _BookmarkSearchPageState();
}

/// Wraps local search results as a single-page "API" response so the
/// regular [LightingList] (cards, detail pager, mute filters) can be reused.
LightSource localBookmarkSource(List<Map<String, dynamic>> illusts) =>
    ApiForceSource(
      futureGet: (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/local/bookmarks'),
        statusCode: 200,
        data: <String, dynamic>{'illusts': illusts, 'next_url': null},
      ),
    );

class _BookmarkSearchPageState extends State<BookmarkSearchPage> {
  late final BookmarkSearchController _controller;
  final TextEditingController _text = TextEditingController();
  LightSource? _source;
  int _sourceGeneration = -1;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';

  String _t(String zh, String en) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _controller = BookmarkSearchController(userId: widget.userId)
      ..addListener(_onChanged)
      ..start();
  }

  void _onChanged() {
    final result = _controller.result;
    if (result != null && _controller.resultGeneration != _sourceGeneration) {
      _sourceGeneration = _controller.resultGeneration;
      _source = localBookmarkSource(result.illusts);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _controller.query;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _buildSearchField(context),
        actions: [
          PopupMenuButton<String>(
            tooltip: _t('更多', 'More'),
            onSelected: (value) async {
              switch (value) {
                case 'sync':
                  await _controller.sync();
                case 'full':
                  await _controller.sync(full: true);
                case 'clear':
                  await _confirmClear();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'sync',
                enabled: !_controller.isSyncing,
                child: Text(_t('同步收藏', 'Sync bookmarks')),
              ),
              PopupMenuItem(
                value: 'full',
                enabled: !_controller.isSyncing,
                child: Text(_t('完整重新同步', 'Full resync')),
              ),
              PopupMenuItem(
                value: 'clear',
                child: Text(_t('清除本地索引', 'Clear local index')),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatus(context),
          _buildFilters(context, query),
          const Divider(height: 1),
          Expanded(child: _buildResults(context)),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) => BookmarkSearchField(
    controller: _text,
    hintText: _t('搜索标题、作者、标签或 PID', 'Title, artist, tag or ID'),
    clearTooltip: _t('清除', 'Clear'),
    onChanged: (value) => _controller.updateQuery(
      _controller.query.copyWith(text: value),
      debounce: true,
    ),
    onSubmitted: (value) =>
        _controller.updateQuery(_controller.query.copyWith(text: value)),
  );

  Widget _buildStatus(BuildContext context) {
    final theme = Theme.of(context);
    final stats = _controller.stats;
    final progress = _controller.syncProgress;
    final String text;
    if (_controller.isSyncing) {
      final scope = progress?.restrict == BookmarkRestrict.private
          ? _t('非公开收藏', 'private')
          : _t('公开收藏', 'public');
      text = _t(
        '正在同步$scope… 第 ${progress?.pages ?? 0} 页 · 新增 ${progress?.added ?? 0}',
        'Syncing $scope… page ${progress?.pages ?? 0} · ${progress?.added ?? 0} new',
      );
    } else if (_controller.syncError != null) {
      text = _t(
        '同步中断：${_controller.syncError}（已同步的内容仍可搜索）',
        'Sync stopped: ${_controller.syncError} (synced works stay searchable)',
      );
    } else {
      text = _t(
        '本地已索引 ${stats.total} 件（公开 ${stats.publicCount} · 非公开 ${stats.privateCount}）'
            '${stats.isComplete ? '' : ' · 尚未同步完'}',
        '${stats.total} indexed (${stats.publicCount} public · '
            '${stats.privateCount} private)'
            '${stats.isComplete ? '' : ' · not fully synced'}',
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_controller.isSyncing) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _controller.syncError != null
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (_controller.isSyncing)
                TextButton(
                  onPressed: _controller.cancelSync,
                  child: Text(_t('停止', 'Stop')),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFilters(BuildContext context, BookmarkLibraryQuery query) {
    Widget choice<T>(String label, T value, T? current, VoidCallback onTap) =>
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            label: Text(label),
            selected: value == current,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => onTap(),
          ),
        );

    void update(BookmarkLibraryQuery next) => _controller.updateQuery(next);

    final sortLabels = <BookmarkLibrarySort, String>{
      BookmarkLibrarySort.bookmarkedNewest: _t('最近收藏', 'Recently saved'),
      BookmarkLibrarySort.bookmarkedOldest: _t('最早收藏', 'Oldest saved'),
      BookmarkLibrarySort.mostBookmarked: _t('收藏数', 'Most bookmarked'),
      BookmarkLibrarySort.mostViewed: _t('浏览数', 'Most viewed'),
      BookmarkLibrarySort.createdNewest: _t('发布时间', 'Newest posted'),
    };

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          PopupMenuButton<BookmarkLibrarySort>(
            initialValue: query.sort,
            onSelected: (sort) => update(query.copyWith(sort: sort)),
            itemBuilder: (_) => [
              for (final entry in sortLabels.entries)
                PopupMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                avatar: const Icon(Icons.sort, size: 18),
                label: Text(sortLabels[query.sort]!),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          choice(_t('全部', 'All'), null, query.type, () {
            update(query.copyWith(clearType: true));
          }),
          choice(_t('插画', 'Illust'), BookmarkWorkType.illust, query.type, () {
            update(query.copyWith(type: BookmarkWorkType.illust));
          }),
          choice(_t('漫画', 'Manga'), BookmarkWorkType.manga, query.type, () {
            update(query.copyWith(type: BookmarkWorkType.manga));
          }),
          choice(_t('动图', 'Ugoira'), BookmarkWorkType.ugoira, query.type, () {
            update(query.copyWith(type: BookmarkWorkType.ugoira));
          }),
          const VerticalDivider(width: 16),
          choice(_t('公开+非公开', 'Both'), null, query.restrict, () {
            update(query.copyWith(clearRestrict: true));
          }),
          choice(
            _t('公开', 'Public'),
            BookmarkRestrict.public,
            query.restrict,
            () {
              update(query.copyWith(restrict: BookmarkRestrict.public));
            },
          ),
          choice(
            _t('非公开', 'Private'),
            BookmarkRestrict.private,
            query.restrict,
            () => update(query.copyWith(restrict: BookmarkRestrict.private)),
          ),
          const VerticalDivider(width: 16),
          choice(
            _t('全年龄+R-18', 'Any age'),
            BookmarkAgeFilter.all,
            query.age,
            () {
              update(query.copyWith(age: BookmarkAgeFilter.all));
            },
          ),
          choice(
            _t('全年龄', 'All ages'),
            BookmarkAgeFilter.allAges,
            query.age,
            () => update(query.copyWith(age: BookmarkAgeFilter.allAges)),
          ),
          choice('R-18', BookmarkAgeFilter.r18, query.age, () {
            update(query.copyWith(age: BookmarkAgeFilter.r18));
          }),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final result = _controller.result;
    final source = _source;
    final theme = Theme.of(context);
    if (result == null || source == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (result.total == 0) {
      final empty = _controller.stats.total == 0;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            empty
                ? _t(
                    '正在把收藏同步到本地，只保存作品信息，不下载图片。\n同步完成后即可按标题、作者、标签搜索。',
                    'Copying your bookmarks to this device (metadata only).\n'
                        'Search becomes available as works arrive.',
                  )
                : _t('没有符合条件的收藏', 'No bookmarks match'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }
    final sort = _controller.query.sort;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              result.total > result.illusts.length
                  ? _t(
                      '共 ${result.total} 件，显示前 ${result.illusts.length} 件',
                      '${result.total} matches, showing ${result.illusts.length}',
                    )
                  : _t('共 ${result.total} 件', '${result.total} matches'),
              style: theme.textTheme.labelMedium,
            ),
          ),
        ),
        Expanded(
          child: LightingList(
            source: source,
            showStats:
                sort == BookmarkLibrarySort.mostBookmarked ||
                sort == BookmarkLibrarySort.mostViewed,
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('清除本地收藏索引？', 'Clear the local index?')),
        content: Text(
          _t(
            '只删除本机的搜索索引，不会影响 Pixiv 上的收藏。下次打开会重新同步。',
            'Only this device\'s search index is removed; your Pixiv '
                'bookmarks are untouched.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_t('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_t('清除', 'Clear')),
          ),
        ],
      ),
    );
    if (confirmed == true) await _controller.clearLibrary();
  }
}

/// Rounded search field matching the main search page's pill style.
class BookmarkSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final String clearTooltip;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  const BookmarkSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.clearTooltip,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.65),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 44,
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => TextField(
              controller: controller,
              textInputAction: TextInputAction.search,
              textAlignVertical: TextAlignVertical.center,
              style: textTheme.bodyLarge,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: hintText,
                hintMaxLines: 1,
                hintStyle: textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  overflow: TextOverflow.ellipsis,
                ),
                prefixIcon: Icon(
                  Icons.search,
                  color: colorScheme.onSurfaceVariant,
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 44,
                  minHeight: 44,
                ),
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: clearTooltip,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 40,
                  minHeight: 40,
                ),
                contentPadding: const EdgeInsets.only(right: 12),
              ),
              onChanged: onChanged,
              onSubmitted: onSubmitted,
            ),
          ),
        ),
      ),
    );
  }
}
