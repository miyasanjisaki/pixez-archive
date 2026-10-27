import 'package:fluent_ui/fluent_ui.dart';
import 'package:pixez/fluent/lighting/fluent_lighting_page.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/models/bookmark_library.dart';
import 'package:pixez/page/user/bookmark/bookmark_search_controller.dart';
import 'package:pixez/page/user/bookmark/bookmark_search_page.dart'
    show localBookmarkSource;

/// Windows (Fluent) variant of the bookmark search page.
class FluentBookmarkSearchPage extends StatefulWidget {
  final int userId;

  const FluentBookmarkSearchPage({super.key, required this.userId});

  @override
  State<FluentBookmarkSearchPage> createState() =>
      _FluentBookmarkSearchPageState();
}

class _FluentBookmarkSearchPageState extends State<FluentBookmarkSearchPage> {
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

  Widget _combo<T>(T value, Map<T, String> labels, ValueChanged<T> onChanged) {
    return ComboBox<T>(
      value: value,
      items: [
        for (final entry in labels.entries)
          ComboBoxItem<T>(value: entry.key, child: Text(entry.value)),
      ],
      onChanged: (next) {
        if (next != null || null is T) onChanged(next as T);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = _controller.query;
    final stats = _controller.stats;
    final progress = _controller.syncProgress;
    final status = _controller.isSyncing
        ? _t(
            '正在同步… 第 ${progress?.pages ?? 0} 页 · 新增 ${progress?.added ?? 0}',
            'Syncing… page ${progress?.pages ?? 0} · ${progress?.added ?? 0} new',
          )
        : _controller.syncError != null
        ? _t(
            '同步中断：${_controller.syncError}',
            'Sync stopped: ${_controller.syncError}',
          )
        : _t(
            '本地已索引 ${stats.total} 件（公开 ${stats.publicCount} · 非公开 ${stats.privateCount}）',
            '${stats.total} indexed (${stats.publicCount} public · ${stats.privateCount} private)',
          );
    final result = _controller.result;
    final source = _source;
    return ScaffoldPage(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextBox(
                    controller: _text,
                    placeholder: _t(
                      '搜索标题、作者、标签或 PID',
                      'Title, artist, tag or ID',
                    ),
                    prefix: const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(FluentIcons.search),
                    ),
                    onChanged: (value) => _controller.updateQuery(
                      _controller.query.copyWith(text: value),
                      debounce: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Button(
                  onPressed: _controller.isSyncing
                      ? _controller.cancelSync
                      : () => _controller.sync(),
                  child: Text(
                    _controller.isSyncing ? _t('停止', 'Stop') : _t('同步', 'Sync'),
                  ),
                ),
                const SizedBox(width: 8),
                Button(
                  onPressed: _controller.isSyncing
                      ? null
                      : () => _controller.sync(full: true),
                  child: Text(_t('完整同步', 'Full resync')),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _combo<BookmarkLibrarySort>(
                  query.sort,
                  {
                    BookmarkLibrarySort.bookmarkedNewest: _t(
                      '最近收藏',
                      'Recently saved',
                    ),
                    BookmarkLibrarySort.bookmarkedOldest: _t(
                      '最早收藏',
                      'Oldest saved',
                    ),
                    BookmarkLibrarySort.mostBookmarked: _t(
                      '收藏数',
                      'Most bookmarked',
                    ),
                    BookmarkLibrarySort.mostViewed: _t('浏览数', 'Most viewed'),
                    BookmarkLibrarySort.createdNewest: _t(
                      '发布时间',
                      'Newest posted',
                    ),
                  },
                  (sort) => _controller.updateQuery(query.copyWith(sort: sort)),
                ),
                _combo<BookmarkWorkType?>(
                  query.type,
                  {
                    null: _t('全部类型', 'All types'),
                    BookmarkWorkType.illust: _t('插画', 'Illust'),
                    BookmarkWorkType.manga: _t('漫画', 'Manga'),
                    BookmarkWorkType.ugoira: _t('动图', 'Ugoira'),
                  },
                  (type) => _controller.updateQuery(
                    query.copyWith(type: type, clearType: type == null),
                  ),
                ),
                _combo<BookmarkRestrict?>(
                  query.restrict,
                  {
                    null: _t('公开+非公开', 'Both'),
                    BookmarkRestrict.public: _t('公开', 'Public'),
                    BookmarkRestrict.private: _t('非公开', 'Private'),
                  },
                  (restrict) => _controller.updateQuery(
                    query.copyWith(
                      restrict: restrict,
                      clearRestrict: restrict == null,
                    ),
                  ),
                ),
                _combo<BookmarkAgeFilter>(
                  query.age,
                  {
                    BookmarkAgeFilter.all: _t('全年龄+R-18', 'Any age'),
                    BookmarkAgeFilter.allAges: _t('全年龄', 'All ages'),
                    BookmarkAgeFilter.r18: 'R-18',
                  },
                  (age) => _controller.updateQuery(query.copyWith(age: age)),
                ),
                Text(status),
                if (result != null)
                  Text(
                    _t('· 共 ${result.total} 件', '· ${result.total} matches'),
                  ),
              ],
            ),
            if (_controller.isSyncing) const ProgressBar(),
          ],
        ),
      ),
      content: result == null || source == null
          ? const Center(child: ProgressRing())
          : result.total == 0
          ? Center(
              child: Text(
                stats.total == 0
                    ? _t(
                        '正在把收藏同步到本地（只保存作品信息）…',
                        'Copying bookmarks to this device…',
                      )
                    : _t('没有符合条件的收藏', 'No bookmarks match'),
              ),
            )
          : LightingList(
              source: source,
              showStats:
                  query.sort == BookmarkLibrarySort.mostBookmarked ||
                  query.sort == BookmarkLibrarySort.mostViewed,
            ),
    );
  }
}
