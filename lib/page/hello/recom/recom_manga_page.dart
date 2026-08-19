import 'package:flutter/material.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/lighting/lighting_page.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/models/illust.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/utils/illust_result_options.dart';

class RecomMangaPage extends StatefulWidget {
  const RecomMangaPage({super.key});

  @override
  State<RecomMangaPage> createState() => _RecomMangaPageState();
}

class _RecomMangaPageState extends State<RecomMangaPage> {
  late final ApiSource _source;
  IllustResultSort _resultSort = IllustResultSort.apiOrder;

  @override
  void initState() {
    super.initState();
    _source = ApiSource(futureGet: apiClient.getMangaRecommend);
  }

  Comparator<Illusts>? get _comparator => buildIllustResultComparator<Illusts>(
    _resultSort,
    bookmarksOf: (illust) => illust.totalBookmarks,
    viewsOf: (illust) => illust.totalView,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(I18n.of(context).manga)),
      body: LightingList(
        source: _source,
        filter: (illust) => illust.type == 'manga',
        comparator: _comparator,
        showStats: true,
        header: _buildSortControls(context),
      ),
                      );
  }

  Widget _buildSortControls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.swap_vert,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              const SizedBox(width: 6),
              Text(
                I18n.of(context).loaded_result_sort,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _sortChip(
                  value: IllustResultSort.apiOrder,
                  label: I18n.of(context).pixiv_sort,
                  icon: Icons.format_list_numbered,
                ),
                const SizedBox(width: 8),
                _sortChip(
                  value: IllustResultSort.bookmarksDesc,
                  label: I18n.of(context).total_bookmark,
                  icon: Icons.bookmark_outline,
                ),
                const SizedBox(width: 8),
                _sortChip(
                  value: IllustResultSort.viewsDesc,
                  label: I18n.of(context).total_view,
                  icon: Icons.visibility_outlined,
                ),
              ],
            ),
          ),
        ],
          ),
        );
  }

  Widget _sortChip({
    required IllustResultSort value,
    required String label,
    required IconData icon,
  }) {
    return ChoiceChip(
      selected: _resultSort == value,
      showCheckmark: false,
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onSelected: (_) {
        if (_resultSort == value) return;
        setState(() => _resultSort = value);
      },
    );
  }
}
