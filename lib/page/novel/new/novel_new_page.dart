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

import 'package:flutter/material.dart';
import 'package:pixez/component/painter_avatar.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/page/follow/follow_list.dart';
import 'package:pixez/page/novel/bookmark/novel_bookmark_page.dart';
import 'package:pixez/page/novel/new/novel_new_list.dart';
import 'package:pixez/page/novel/new/novel_watch_list.dart';
import 'package:pixez/page/novel/user/novel_users_page.dart';
import 'package:pixez/utils/haptic_util.dart';

class NovelNewPage extends StatefulWidget {
  final bool embedded;

  const NovelNewPage({super.key, this.embedded = false});

  @override
  State<NovelNewPage> createState() => _NovelNewPageState();
}

class _NovelNewPageState extends State<NovelNewPage>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late TabController _tabController;

  @override
  void initState() {
    _tabController = TabController(length: 4, vsync: this);
    super.initState();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tabs = TabBar(
      onTap: (_) => HapticUtil.selectionClick(),
              controller: _tabController,
              isScrollable: true,
              tabs: [
        Tab(text: I18n.of(context).news),
        Tab(text: I18n.of(context).bookmark),
        Tab(text: I18n.of(context).watchlist),
        Tab(text: I18n.of(context).follow),
              ],
    );
    final accountAction = _buildAccountAction(context);
    return Column(
      children: [
        if (widget.embedded)
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: Row(
              children: [
                Expanded(child: tabs),
                if (accountAction != null) accountAction,
            ],
          ),
          )
        else
          AppBar(
            title: tabs,
            actions: [if (accountAction != null) accountAction],
          ),
          Expanded(
              child: TabBarView(
            controller: _tabController,
            children: [
              NovelNewList(),
              NovelBookmarkPage(),
              accountStore.now != null ? NovelWatchList() : Container(),
              accountStore.now != null
                  ? FollowList(
                      id: int.parse(accountStore.now!.userId),
                      isNovel: true,
                    )
                  : Container(),
            ],
          ),
        ),
        ],
    );
  }

  Widget? _buildAccountAction(BuildContext context) {
    final account = accountStore.now;
    if (account == null) return null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SizedBox(
        height: 28,
        width: 28,
        child: PainterAvatar(
          url: account.userImage,
          id: int.parse(account.userId),
          onTap: () => Leader.push(
            context,
            NovelUsersPage(id: int.parse(account.userId)),
          ),
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
