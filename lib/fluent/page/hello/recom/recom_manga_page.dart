import 'package:fluent_ui/fluent_ui.dart';
import 'package:pixez/fluent/lighting/fluent_lighting_page.dart';
import 'package:pixez/i18n.dart';
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
    return ScaffoldPage(
      header: PageHeader(title: Text(I18n.of(context).manga)),
      content: LightingList(
        source: _source,
        filter: (illust) => illust.type == 'manga',
        comparator: _comparator,
        showStats: true,
        header: _buildSortControls(context),
      ),
                      );
  }

  Widget _buildSortControls(BuildContext context) {
    final labels = <IllustResultSort, String>{
      IllustResultSort.apiOrder: I18n.of(context).pixiv_sort,
      IllustResultSort.bookmarksDesc: I18n.of(context).total_bookmark,
      IllustResultSort.viewsDesc: I18n.of(context).total_view,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            I18n.of(context).loaded_result_sort,
            style: FluentTheme.of(context).typography.bodyStrong,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in labels.entries)
                ToggleButton(
                  checked: _resultSort == entry.key,
                  onChanged: (_) {
                    if (_resultSort == entry.key) return;
                    setState(() => _resultSort = entry.key);
                    },
                  child: Text(entry.value),
                  ),
            ],
          ),
        ],
          ),
    );
  }
}
