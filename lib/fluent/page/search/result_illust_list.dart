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

import 'package:bot_toast/bot_toast.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/fluent/lighting/fluent_lighting_page.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/illust.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/page/search/result_illust_store.dart';
import 'package:pixez/utils/illust_result_options.dart';

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

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    futureGet = ApiForceSource(
        futureGet: (e) => apiClient.getSearchIllust(widget.word));
    listen = topStore.topStream.listen((event) {
      if (event == "401" && _scrollController.hasClients) {
        _scrollController.position.jumpTo(0);
      }
    });
  }

  @override
  void dispose() {
    listen.cancel();
    _scrollController.dispose();
    super.dispose();
  }

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
  IllustResultSort loadedResultSort = IllustResultSort.apiOrder;
  IllustContentFilter contentFilter = IllustContentFilter.all;
  int selectStarNum = 0;
  // double starValue = 0.0;

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: Align(
        alignment: Alignment.centerRight,
        child: Row(
          children: [
            IconButton(
                icon: Icon(FluentIcons.date_time),
                onPressed: null),
            _buildStar(),
            IconButton(
                icon: Icon(FluentIcons.filter),
                onPressed: () {
                  _buildShowBottomSheet(context);
                  // _showMaterialBottom();
                }),
          ],
        ),
      ),
      content: LightingList(
        source: futureGet,
        scrollController: _scrollController,
        filter: contentFilter == IllustContentFilter.all
            ? null
            : _matchesContentFilter,
        comparator: buildIllustResultComparator<Illusts>(
          loadedResultSort,
          bookmarksOf: (illust) => illust.totalBookmarks,
          viewsOf: (illust) => illust.totalView,
        ),
      ),
    );
  }

  bool _matchesContentFilter(Illusts illust) =>
      matchesIllustContent(illust.type, contentFilter);

  DateTimeRange? _dateTimeRange;

  _changeQueryParams() {
    if (_starValue == 0)
      futureGet = ApiForceSource(
          futureGet: (bool e) => apiClient.getSearchIllust(widget.word,
              search_target: searchTarget,
              sort: selectSort,
              start_date: _dateTimeRange?.start,
              end_date: _dateTimeRange?.end,
              bookmark_num: null));
    else
      futureGet = ApiForceSource(
          futureGet: (bool e) => apiClient.getSearchIllust(
              '${widget.word} ${_starValue}users入り',
              search_target: searchTarget,
              sort: selectSort,
              start_date: _dateTimeRange?.start,
              end_date: _dateTimeRange?.end,
              bookmark_num: null));
  }

  void _buildShowBottomSheet(BuildContext context) {
    var pendingSearchTarget = searchTarget;
    var pendingSelectSort = selectSort;
    var pendingLoadedResultSort = loadedResultSort;
    var pendingContentFilter = contentFilter;
    final isPremium = accountStore.now?.isPremium == 1;
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(I18n.of(context).filter),
        content: StatefulBuilder(builder: (_, setS) {
          return SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => Container(
                width: constraints.maxWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: SizedBox(
                        width: double.infinity,
                        child: ComboBox<int>(
                          value: search_target.indexOf(pendingSearchTarget),
                          items: [
                            ComboBoxItem(
                              child:
                                  Text(I18n.of(context).partial_match_for_tag),
                              value: 0,
                            ),
                            ComboBoxItem(
                              child: Text(I18n.of(context).exact_match_for_tag),
                              value: 1,
                            ),
                            ComboBoxItem(
                              child: Text(I18n.of(context).title_and_caption),
                              value: 2,
                            ),
                          ],
                          onChanged: (int? index) {
                            if (index == null) return;
                            setS(() {
                              pendingSearchTarget = search_target[index];
                            });
                          },
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: SizedBox(
                        width: double.infinity,
                        child: ComboBox<int>(
                          value: sort.indexOf(pendingSelectSort),
                          items: [
                            ComboBoxItem(
                              child: Text(I18n.of(context).date_desc),
                              value: 0,
                            ),
                            ComboBoxItem(
                              child: Text(I18n.of(context).date_asc),
                              value: 1,
                            ),
                            ComboBoxItem(
                              child: Text(I18n.of(context).popular_desc),
                              value: 2,
                            ),
                            if (isPremium) ...[
                              ComboBoxItem(
                                child:
                                    Text(I18n.of(context).popular_male_desc),
                                value: 3,
                              ),
                              ComboBoxItem(
                                child:
                                    Text(I18n.of(context).popular_female_desc),
                                value: 4,
                              ),
                            ],
                          ],
                          onChanged: (int? index) {
                            if (index == null) return;
                            if (!isPremium && index == 2) {
                              BotToast.showText(text: 'not premium');
                              setState(() {
                                futureGet = ApiForceSource(
                                    futureGet: (bool e) =>
                                        apiClient.getPopularPreview(widget.word));
                              });
                              Navigator.of(context).pop();
                              return;
                            }
                            setS(() {
                              pendingSelectSort = sort[index];
                            });
                          },
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: SizedBox(
                        width: double.infinity,
                        child: ComboBox<IllustResultSort>(
                          value: pendingLoadedResultSort,
                          items: [
                            ComboBoxItem(
                              value: IllustResultSort.apiOrder,
                              child: Text(I18n.of(context).default_title),
                            ),
                            ComboBoxItem(
                              value: IllustResultSort.bookmarksDesc,
                              child:
                                  Text('${I18n.of(context).total_bookmark} ↓'),
                            ),
                            ComboBoxItem(
                              value: IllustResultSort.viewsDesc,
                              child: Text('${I18n.of(context).total_view} ↓'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setS(() {
                              pendingLoadedResultSort = value;
                            });
                          },
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: SizedBox(
                        width: double.infinity,
                        child: ComboBox<IllustContentFilter>(
                          value: pendingContentFilter,
                          items: [
                            ComboBoxItem(
                              value: IllustContentFilter.all,
                              child: Text(I18n.of(context).all),
                            ),
                            ComboBoxItem(
                              value: IllustContentFilter.illustration,
                              child: Text(I18n.of(context).illust),
                            ),
                            ComboBoxItem(
                              value: IllustContentFilter.manga,
                              child: Text(I18n.of(context).manga),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setS(() {
                              pendingContentFilter = value;
                            });
                          },
                        ),
                      ),
                    ),
                    Container(
                      height: 16,
                    )
                  ],
                ),
              ),
            ),
          );
        }),
        actions: [
          FilledButton(
            onPressed: () {
              final serverQueryChanged =
                  pendingSearchTarget != searchTarget ||
                      pendingSelectSort != selectSort;
              setState(() {
                searchTarget = pendingSearchTarget;
                selectSort = pendingSelectSort;
                loadedResultSort = pendingLoadedResultSort;
                contentFilter = pendingContentFilter;
                if (serverQueryChanged) _changeQueryParams();
              });
              Navigator.of(context).pop();
            },
            child: Text(I18n.of(context).apply),
          ),
          Button(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: Text(I18n.of(context).cancel),
          ),
        ],
      ),
    );
  }

  int _starValue = 0;

  Widget _buildStar() {
    return ComboBox(
        value: _starValue,
        icon: Icon(FluentIcons.sort),
        items: starNum.map((int value) {
          if (value > 0) {
            return ComboBoxItem(
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
            return ComboBoxItem(
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
        }).toList());
  }
}
