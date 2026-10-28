import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/er/hoster.dart';
import 'package:pixez/models/bookmark_library_query.dart';
import 'package:pixez/page/user/bookmark/bookmark_search_page.dart'
    show BookmarkSearchField;

bool _isChinese(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh';

/// Circular Pixiv avatar that never navigates on tap.
class BookmarkArtistAvatar extends StatelessWidget {
  final String? url;
  final double size;

  const BookmarkArtistAvatar({super.key, required this.url, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final placeholder = CircleAvatar(
      radius: size / 2,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.person, size: size * 0.6),
    );
    final value = url;
    if (value == null || value.isEmpty) return placeholder;
    return CachedNetworkImage(
      imageUrl: value,
      httpHeaders: Hoster.header(url: value),
      cacheManager: pixivCacheManager,
      imageBuilder: (context, image) =>
          CircleAvatar(radius: size / 2, backgroundImage: image),
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }
}

/// Horizontal row of the most used bookmark tags, plus an "all tags" entry.
class BookmarkTagChipsRow extends StatelessWidget {
  final List<BookmarkTagFacet> tags;
  final String? selectedTag;
  final ValueChanged<String?> onSelected;
  final int maximumChips;

  const BookmarkTagChipsRow({
    super.key,
    required this.tags,
    required this.selectedTag,
    required this.onSelected,
    this.maximumChips = 20,
  });

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    final zh = _isChinese(context);
    final visible = tags.take(maximumChips).toList();
    final selected = selectedTag;
    // Keep a tag picked from the full list visible at the front.
    if (selected != null && !visible.any((tag) => tag.name == selected)) {
      final picked = tags.where((tag) => tag.name == selected);
      visible.insert(
        0,
        picked.isEmpty
            ? BookmarkTagFacet(name: selected, count: 0)
            : picked.first,
      );
    }
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ActionChip(
              avatar: const Icon(Icons.sell_outlined, size: 18),
              label: Text(zh ? '全部标签' : 'All tags'),
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                final picked = await showBookmarkTagPicker(context, tags);
                if (picked != null) onSelected(picked.name);
              },
            ),
          ),
          for (final tag in visible)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                selected: tag.name == selected,
                label: Text(
                  tag.count > 0 ? '#${tag.name}  ${tag.count}' : '#${tag.name}',
                ),
                tooltip: tag.translatedName,
                onSelected: (_) =>
                    onSelected(tag.name == selected ? null : tag.name),
              ),
            ),
        ],
      ),
    );
  }
}

Future<BookmarkTagFacet?> showBookmarkTagPicker(
  BuildContext context,
  List<BookmarkTagFacet> tags,
) {
  final zh = _isChinese(context);
  return _showFacetPicker<BookmarkTagFacet>(
    context,
    title: zh ? '收藏中的标签（${tags.length}）' : 'Tags in your bookmarks',
    hint: zh ? '筛选标签' : 'Filter tags',
    items: tags,
    matches: (tag, query) =>
        tag.name.toLowerCase().contains(query) ||
        (tag.translatedName?.toLowerCase().contains(query) ?? false),
    tileBuilder: (context, tag) => ListTile(
      leading: const Icon(Icons.tag),
      title: Text(tag.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: tag.translatedName == null
          ? null
          : Text(
              tag.translatedName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Text('${tag.count}'),
      onTap: () => Navigator.of(context).pop(tag),
    ),
  );
}

Future<BookmarkArtistFacet?> showBookmarkArtistPicker(
  BuildContext context,
  List<BookmarkArtistFacet> artists,
) {
  final zh = _isChinese(context);
  return _showFacetPicker<BookmarkArtistFacet>(
    context,
    title: zh ? '收藏中的画师（${artists.length}）' : 'Artists in your bookmarks',
    hint: zh ? '筛选画师' : 'Filter artists',
    items: artists,
    matches: (artist, query) =>
        artist.name.toLowerCase().contains(query) ||
        artist.id.toString() == query,
    tileBuilder: (context, artist) => ListTile(
      leading: BookmarkArtistAvatar(url: artist.avatarUrl),
      title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(zh ? '${artist.count} 件' : '${artist.count}'),
      onTap: () => Navigator.of(context).pop(artist),
    ),
  );
}

Future<T?> _showFacetPicker<T>(
  BuildContext context, {
  required String title,
  required String hint,
  required List<T> items,
  required bool Function(T item, String query) matches,
  required Widget Function(BuildContext context, T item) tileBuilder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => _FacetPickerSheet<T>(
      title: title,
      hint: hint,
      items: items,
      matches: matches,
      tileBuilder: tileBuilder,
    ),
  );
}

class _FacetPickerSheet<T> extends StatefulWidget {
  final String title;
  final String hint;
  final List<T> items;
  final bool Function(T item, String query) matches;
  final Widget Function(BuildContext context, T item) tileBuilder;

  const _FacetPickerSheet({
    super.key,
    required this.title,
    required this.hint,
    required this.items,
    required this.matches,
    required this.tileBuilder,
  });

  @override
  State<_FacetPickerSheet<T>> createState() => _FacetPickerSheetState<T>();
}

class _FacetPickerSheetState<T> extends State<_FacetPickerSheet<T>> {
  final TextEditingController _text = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? widget.items
        : widget.items.where((item) => widget.matches(item, _query)).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              widget.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
            child: BookmarkSearchField(
              controller: _text,
              hintText: widget.hint,
              clearTooltip: _isChinese(context) ? '清除' : 'Clear',
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
              onSubmitted: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
              ),
              itemCount: filtered.length,
              itemBuilder: (context, index) =>
                  widget.tileBuilder(context, filtered[index]),
            ),
          ),
        ],
      ),
    );
  }
}
