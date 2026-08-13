import 'package:flutter/material.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/page/search/suggest/search_suggestion_page.dart';

class SearchBar extends StatelessWidget {
  final VoidCallback? onSaucenao;
  final VoidCallback? onSearch;
  final bool imageSearchBusy;

  const SearchBar({
    Key? key,
    this.onSaucenao,
    this.onSearch,
    this.imageSearchBusy = false,
  }) : super(key: key);

  void _openSearch(BuildContext context) {
    final callback = onSearch;
    if (callback != null) {
      callback();
      return;
    }
    Navigator.push(
      context,
      PageRouteBuilder(pageBuilder: (_, __, ___) => SearchSuggestionPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final searchHint = I18n.of(context).search_word_hint;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.65),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 56,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: searchHint,
                  child: InkWell(
                    key: const Key('text_search_action'),
                    onTap: () => _openSearch(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Icon(
                            Icons.search,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              searchHint,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: I18n.of(context).image_search,
                icon: imageSearchBusy
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Icon(Icons.image_search_outlined),
                onPressed: imageSearchBusy ? null : onSaucenao,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}
