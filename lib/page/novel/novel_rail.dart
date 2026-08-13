/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful, but WITHOUT ANY
 *  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 *  FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with
 *  this program. If not, see <http://www.gnu.org/licenses/>.
 */
import 'package:flutter/material.dart';
import 'package:pixez/constants.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/page/novel/new/novel_new_page.dart';
import 'package:pixez/page/novel/rank/novel_rank_page.dart';
import 'package:pixez/utils/haptic_util.dart';
import 'package:pixez/page/novel/recom/novel_recom_page.dart';
import 'package:pixez/page/novel/search/novel_search_page.dart';

class NovelRail extends StatefulWidget {
  const NovelRail({super.key});

  @override
  State<NovelRail> createState() => _NovelRailState();
}

class _NovelRailState extends State<NovelRail>
    with SingleTickerProviderStateMixin {
  static const int _sectionCount = 4;

  late final TabController _tabController;
  late final List<Widget> _pageList;
  late final int _previousContentType;
  late final BuildContext? _previousFetcherContext;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _sectionCount, vsync: this);
    _pageList = const [
      NovelRecomPage(embedded: true),
      NovelRankPage(embedded: true),
      NovelNewPage(embedded: true),
      NovelSearchPage(embedded: true),
    ];
    _previousContentType = Constants.type;
    _previousFetcherContext = fetcher.context;
    Constants.type = 1;
    fetcher.context = context;
  }

  @override
  void dispose() {
    Constants.type = _previousContentType;
    fetcher.context = _previousFetcherContext;
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !Constants.isFluent,
        title: Text(I18n.of(context).novel),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.center,
          onTap: (_) => HapticUtil.selectionClick(),
          tabs: [
            Tab(
              icon: const Icon(Icons.auto_stories),
              text: I18n.of(context).recommend,
      ),
            Tab(
              icon: const Icon(Icons.leaderboard),
              text: I18n.of(context).rank,
            ),
            Tab(icon: const Icon(Icons.favorite), text: I18n.of(context).news),
            Tab(icon: const Icon(Icons.search), text: I18n.of(context).search),
      ],
        ),
      ),
      body: TabBarView(controller: _tabController, children: _pageList),
    );
  }
}
