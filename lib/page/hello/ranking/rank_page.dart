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
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/illust_bookmark_tags_response.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/page/hello/ranking/rank_store.dart';
import 'package:pixez/page/hello/ranking/ranking_mode/rank_mode_page.dart';
import 'package:pixez/page/search/result_illust_list.dart';
import 'package:pixez/utils/bookmark_interest_tags.dart';
import 'package:pixez/utils/haptic_util.dart';
import 'package:pixez/utils/ranking_choice_layout.dart';

class RankPage extends StatefulWidget {
  RankPage({Key? key});

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
    "day_ai",
    "day_r18_ai",
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
  bool _preferencesReady = false;
  final Set<String> _selectedInterestTags = <String>{};

  @override
  void dispose() {
    subscription.cancel();
    super.dispose();
  }

  @override
  void initState() {
    nowDate = DateTime.now();
    rankStore = RankStore();
    int i = 0;
    modeList.forEach((element) {
      boolList[i] = false;
      i++;
    });
    super.initState();
    subscription = topStore.topStream.listen((event) {
      if (event == "200" && index < rankStore.modeList.length) {
        topStore.setTop((201 + index).toString());
      }
    });
    _initializePreferences();
  }

  Future<void> _initializePreferences() async {
    await rankStore.init();
    for (var i = 0; i < modeList.length; i++) {
      boolList[i] = rankStore.modeList.contains(modeList[i]);
    }
    _selectedInterestTags
      ..clear()
      ..addAll(rankStore.tagList);
    if (!mounted) return;
    setState(() => _preferencesReady = true);
    await _refreshInterestTags();
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

  String? toRequestDate(DateTime dateTime) {
    return "${dateTime.year}-${dateTime.month}-${dateTime.day}";
  }

  DateTime nowDateTime = DateTime.now();
  int index = 0;
  int tapCount = 0;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final rankListMean = I18n.of(context).mode_list.split(' ');
    return Observer(
      builder: (_) {
        if (!_preferencesReady) {
          return const Center(child: CircularProgressIndicator());
        }
        if (rankStore.inChoice) {
          return _buildChoicePage(context, rankListMean);
        }
        final savedModes = rankStore.modeList.toList(growable: false);
        final savedTags = rankStore.tagList.toList(growable: false);
        final tabCount = savedModes.length + savedTags.length;
        if (tabCount > 0) {
          var list = I18n.of(context).mode_list.split(' ');
          List<String> titles = [];
          for (final mode in savedModes) {
            final modeIndex = modeList.indexOf(mode);
            titles.add(
              modeIndex >= 0 && modeIndex < list.length
                  ? list[modeIndex]
                  : mode,
            );
          }
          titles.addAll(savedTags);
          return DefaultTabController(
            length: tabCount,
            child: Column(
              children: <Widget>[
                AnimatedContainer(
                  duration: Duration(milliseconds: 400),
                  height: !fullScreenStore.fullscreen
                      ? (kToolbarHeight + MediaQuery.of(context).padding.top)
                      : 0,
                  child: AppBar(
                    title: TabBar(
                      onTap: (i) {
                        HapticUtil.selectionClick();
                        setState(() {
                          this.index = i;
                        });
                      },
                      tabAlignment: TabAlignment.start,
                      indicatorSize: TabBarIndicatorSize.label,
                      isScrollable: true,
                      tabs: <Widget>[for (var i in titles) Tab(text: i)],
                    ),
                    actions: <Widget>[
                      if (Platform.isAndroid)
                        IconButton(
                          icon: Icon(Icons.fullscreen),
                          onPressed: () {
                            fullScreenStore.toggle();
                          },
                        ),
                      Visibility(
                        visible: index < savedModes.length,
                        child: IconButton(
                          icon: Icon(Icons.date_range),
                          onPressed: () async {
                            await _showTimePicker(context);
                          },
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.undo),
                        onPressed: _resetChoices,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      for (var element in savedModes)
                        RankModePage(
                          date: dateTime,
                          mode: element,
                          index: savedModes.indexOf(element),
                        ),
                      for (final tag in savedTags)
                        ResultIllustList(
                          key: ValueKey('ranking-interest:$tag'),
                          word: tag,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        } else {
          return _buildChoicePage(context, rankListMean);
        }
      },
    );
  }

  Widget _buildChoicePage(BuildContext context, List<String> rankListMean) {
    final mediaQuery = MediaQuery.of(context);
    final bottomPadding = calculateRankingChoiceBottomPadding(
      viewportWidth: mediaQuery.size.width,
      viewportHeight: mediaQuery.size.height,
      systemBottomPadding: mediaQuery.viewPadding.bottom,
    );
    return Container(
      child: Column(
        children: <Widget>[
          AppBar(
            elevation: 0.0,
            title: Text(I18n.of(context).choice_you_like),
            actions: <Widget>[
              IconButton(
                icon: Icon(Icons.save),
                onPressed: () async {
                  await rankStore.saveChange(
                    boolList,
                    selectedTags: _selectedInterestTags,
                  );
                  index = 0;
                  rankStore.setInChoice(false);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                rankingChoiceContentPadding,
                rankingChoiceContentPadding,
                rankingChoiceContentPadding,
                bottomPadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (var e in rankListMean)
                        FilterChip(
                          label: Text(e),
                          selected: boolList[rankListMean.indexOf(e)] ?? false,
                          onSelected: (v) {
                            setState(() {
                              boolList[rankListMean.indexOf(e)] = v;
                            });
                          },
                        ),
                    ],
                  ),
                  const Divider(height: 32),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          I18n.of(context).favorited_tag,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: I18n.of(context).refresh,
                        onPressed: _loadingInterestTags
                            ? null
                            : _refreshInterestTags,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  if (_loadingInterestTags) const LinearProgressIndicator(),
                  if (_interestTagsFailed && _interestTags.isEmpty)
                    TextButton.icon(
                      onPressed: _refreshInterestTags,
                      icon: const Icon(Icons.refresh),
                      label: Text(
                        I18n.of(context).loading_failed_retry_message,
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
                            FilterChip(
                              label: Text(
                                tag.count > 0
                                    ? '${tag.name} · ${tag.count}'
                                    : tag.name,
                              ),
                              selected: _selectedInterestTags.contains(
                                tag.name,
                              ),
                              onSelected: (selected) {
                                setState(() {
                                  if (selected) {
                                    _selectedInterestTags.add(tag.name);
                                  } else {
                                    _selectedInterestTags.remove(tag.name);
                                  }
                                });
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _resetChoices() async {
    for (var i = 0; i < modeList.length; i++) {
      boolList[i] = false;
    }
    _selectedInterestTags.clear();
    index = 0;
    await rankStore.reset();
    if (mounted) setState(() {});
  }

  Future _showTimePicker(BuildContext context) async {
    var nowdate = DateTime.now();
    var date = await showDatePicker(
      context: context,
      initialDate: nowDateTime,
      locale: userSetting.locale,
      firstDate: DateTime(2007, 8),
      //pixiv于2007年9月10日由上谷隆宏等人首次推出第一个测试版...
      lastDate: nowdate,
    );
    if (date != null && mounted) {
      nowDateTime = date;
      setState(() {
        this.dateTime = toRequestDate(date);
      });
    }
  }

  @override
  bool get wantKeepAlive => true;
}
