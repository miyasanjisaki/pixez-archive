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

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/er/fluent_leader.dart';
import 'package:pixez/fluent/page/search/result_page.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/illust_bookmark_tags_response.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/page/hello/ranking/rank_store.dart';
import 'package:pixez/fluent/page/hello/ranking/ranking_mode/rank_mode_page.dart';
import 'package:pixez/utils/bookmark_interest_tags.dart';

class RankPage extends StatefulWidget {
  const RankPage({super.key});

  @override
  _RankPageState createState() => _RankPageState();
}

class _RankPageState extends State<RankPage>
    with AutomaticKeepAliveClientMixin {
  late RankStore rankStore;
  final modeList = [
    "day",
    "day_male",
    "day_female",
    "week_original",
    "week_rookie",
    "week",
    "month",
    "day_r18",
    "week_r18",
    "week_r18g",
  ];
  var boolList = Map<int, bool>();
  late DateTime nowDate;
  late StreamSubscription<String> subscription;
  String? dateTime;
  List<BookmarkInterestTag> _interestTags = const [];
  bool _loadingInterestTags = false;
  bool _interestTagsFailed = false;
  bool _choiceDialogOpen = false;

  GlobalKey appBarKey = GlobalKey();
  ValueNotifier<double?> appBarHeightNotifier = ValueNotifier(null);

  @override
  void dispose() {
    subscription.cancel();
    super.dispose();
  }

  @override
  void initState() {
    nowDate = DateTime.now();
    rankStore = RankStore()..init();
    int i = 0;
    modeList.forEach((element) {
      boolList[i] = false;
      i++;
    });
    super.initState();
    subscription = topStore.topStream.listen((event) {
      if (event == "200") {
        topStore.setTop((201 + index).toString());
      }
    });

    Future.delayed(Duration.zero, () {
      if (rankStore.inChoice || rankStore.modeList.isEmpty) {
        final rankListMean = I18n.of(context).mode_list.split(' ');
        _choicePage(context, rankListMean);
      }
      _refreshInterestTags();
    });
  }

  Future<List<BookmarkTag>> _loadBookmarkTags(int userId, String restrict) {
    return collectBookmarkTagPages(
      firstPage: () => apiClient.getUserBookmarkTagsIllust(
        userId,
        restrict: restrict,
        force: true,
      ),
      nextPage: (url) async {
        final response = await apiClient.getNext(url);
        return IllustBookmarkTagsResponse.fromJson(response.data);
      },
    );
  }

  Future<void> _refreshInterestTags() async {
    if (_loadingInterestTags) return;
    if (mounted) {
      setState(() {
        _loadingInterestTags = true;
        _interestTagsFailed = false;
      });
    }

    final remoteTags = <BookmarkTag>[];
    var failed = false;
    final userId = int.tryParse(accountStore.now?.userId ?? '');
    if (userId != null) {
      final pages = await Future.wait(
        const ['public', 'private'].map((restrict) async {
          try {
            return await _loadBookmarkTags(userId, restrict);
          } catch (_) {
            failed = true;
            return <BookmarkTag>[];
          }
        }),
      );
      for (final page in pages) {
        remoteTags.addAll(page);
      }
    }

    try {
      await bookTagStore.init();
    } catch (_) {
      failed = true;
    }
    final merged = mergeBookmarkInterestTags(
      remoteTags: remoteTags,
      localTags: bookTagStore.bookTagList,
    );
    if (!mounted) return;
    setState(() {
      _interestTags = merged;
      _interestTagsFailed = failed;
      _loadingInterestTags = false;
    });
  }

  String toRequestDate(DateTime dateTime) {
    return "${dateTime.year}-${dateTime.month}-${dateTime.day}";
  }

  DateTime nowDateTime = DateTime.now();
  int index = 0;
  int tapCount = 0;

  // 获取AppBar的高度，方便实现动画
  Future<double> initAppBarHeight() async {
    Size? appBarSize = appBarKey.currentContext
        ?.findRenderObject()
        ?.paintBounds
        .size;
    if (appBarSize != null) {
      return appBarSize.height;
    } else {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final rankListMean = I18n.of(context).mode_list.split(' ');
    return Observer(
      builder: (_) {
        if (rankStore.inChoice) {
          return Container(
            child: Center(
              child: FilledButton(
                child: Text(I18n.of(context).choice_you_like),
                onPressed: () => _choicePage(context, rankListMean),
              ),
            ),
          );
        }
        if (rankStore.modeList.isNotEmpty) {
          var list = I18n.of(context).mode_list.split(' ');
          List<String> titles = [];
          for (var i = 0; i < rankStore.modeList.length; i++) {
            int index = modeList.indexOf(rankStore.modeList[i]);
            if (index < 0) {
              debugPrint(rankStore.modeList[i] + ' is -1');
              continue;
            }
            titles.add(list[index]);
          }
          return NavigationView(
            pane: NavigationPane(
              header: IconButton(
                icon: Icon(WindowsIcons.return_to_window),
                onPressed: () {
                  rankStore.reset();
                  _choicePage(context, rankListMean);
                },
              ),
              selected: index,
              onChanged: (value) => setState(() => index = value),
              displayMode: PaneDisplayMode.top,
              items: [
                for (int i = 0; i < titles.length; i++)
                  PaneItem(
                    icon: Icon(FluentIcons.context_menu),
                    title: Text(titles[i]),
                    body: RankModePage(
                      date: dateTime,
                      mode: rankStore.modeList[i],
                      index: i,
                    ),
                  ),
              ],
              footerItems: [
                PaneItemWidgetAdapter(
                  child: CalendarDatePicker(
                    initialStart: nowDateTime,
                    onSelectionChanged: (value) {
                      nowDateTime = value.selectedDates[0];
                      this.dateTime = toRequestDate(nowDateTime);
                    },
                    locale: userSetting.locale,
                    minDate: DateTime(2007, 8),
                    //pixiv于2007年9月10日由上谷隆宏等人首次推出第一个测试版...
                    maxDate: DateTime.now(),
                  ),
                ),
              ],
            ),
          );
        } else {
          return Container(
            child: Center(
              child: FilledButton(
                child: Text(I18n.of(context).choice_you_like),
                onPressed: () => _choicePage(context, rankListMean),
              ),
            ),
          );
        }
      },
    );
  }

  Future<void> _choicePage(
    BuildContext pageContext,
    List<String> rankListMean,
  ) async {
    if (_choiceDialogOpen) return;
    _choiceDialogOpen = true;
    try {
      if (_interestTags.isEmpty && !_loadingInterestTags) {
        await _refreshInterestTags();
      }
      if (!pageContext.mounted) return;
      await showDialog(
        context: pageContext,
        useRootNavigator: false,
        builder: (dialogContext) => ContentDialog(
          title: Text(I18n.of(dialogContext).choice_you_like),
          content: StatefulBuilder(
            builder: (dialogContext, dialogSetState) => SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var value in rankListMean)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                        vertical: 2.0,
                      ),
                      child: Checkbox(
                        content: Text(value),
                        checked: _rankFilters.contains(value),
                        onChanged: (v) {
                          boolList[rankListMean.indexOf(value)] = v ?? false;
                          if (v ?? false) {
                            dialogSetState(() {
                              _rankFilters.add(value);
                            });
                          } else {
                            dialogSetState(() {
                              _rankFilters.remove(value);
                            });
                          }
                        },
                      ),
                    ),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          I18n.of(dialogContext).favorited_tag,
                          style: FluentTheme.of(
                            dialogContext,
                          ).typography.subtitle,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(FluentIcons.refresh),
                        onPressed: _loadingInterestTags
                            ? null
                            : () async {
                                await _refreshInterestTags();
                                if (dialogContext.mounted) {
                                  dialogSetState(() {});
                                }
                              },
                      ),
                    ],
                  ),
                  if (_loadingInterestTags) const ProgressBar(),
                  if (_interestTagsFailed && _interestTags.isEmpty)
                    Button(
                      onPressed: () async {
                        await _refreshInterestTags();
                        if (dialogContext.mounted) {
                          dialogSetState(() {});
                        }
                      },
                      child: Text(
                        I18n.of(dialogContext).loading_failed_retry_message,
                      ),
                    ),
                  if (_interestTags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final tag in _interestTags)
                            Button(
                              child: Text(
                                tag.count > 0
                                    ? '${tag.name} · ${tag.count}'
                                    : tag.name,
                              ),
                              onPressed: () {
                                Navigator.of(dialogContext).pop();
                                FluentLeader.push(
                                  pageContext,
                                  ResultPage(word: tag.name),
                                  icon: const Icon(FluentIcons.search),
                                  title: Text(tag.name),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            FilledButton(
              child: Text(I18n.of(dialogContext).ok),
              onPressed: () async {
                await rankStore.saveChange(boolList);
                rankStore.inChoice = false;
                Navigator.of(dialogContext).pop();
              },
            ),
          ],
        ),
      );
    } finally {
      _choiceDialogOpen = false;
    }
  }

  List<String> _rankFilters = [];

  @override
  bool get wantKeepAlive => true;
}
