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

import 'package:easy_refresh/easy_refresh.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/page/user/bookmark/tag/bookmark_tag_store.dart';

class UserBookmarkTagPage extends StatefulWidget {
  @override
  _UserBookmarkTagPageState createState() => _UserBookmarkTagPageState();
}

class _UserBookmarkTagPageState extends State<UserBookmarkTagPage>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(title: Text(I18n.of(context).tag)),
      content: NavigationView(
        pane: NavigationPane(
          items: [
            PaneItem(
              icon: Icon(FluentIcons.public_folder),
              title: Text(I18n.of(context).public),
              body: NewWidget(restrict: "public"),
            ),
            PaneItem(
              icon: Icon(FluentIcons.lock),
              title: Text(I18n.of(context).private),
              body: NewWidget(restrict: "private"),
            ),
          ],
          displayMode: PaneDisplayMode.top,
        ),
      ),
    );
  }
}

class NewWidget extends StatefulWidget {
  final String restrict;

  const NewWidget({Key? key, required this.restrict}) : super(key: key);

  @override
  State<NewWidget> createState() => _NewWidgetState();
}

class _NewWidgetState extends State<NewWidget> {
  final EasyRefreshController _easyRefreshController = EasyRefreshController(
    controlFinishLoad: true,
    controlFinishRefresh: true,
  );
  late final BookMarkTagStore _bookMarkTagStore;

  @override
  void initState() {
    super.initState();
    _bookMarkTagStore = BookMarkTagStore(
      int.parse(accountStore.now!.userId),
      _easyRefreshController,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bookMarkTagStore.fetch(widget.restrict);
    });
  }

  @override
  void dispose() {
    _easyRefreshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (_) {
        return EasyRefresh(
          controller: _easyRefreshController,
          refreshOnStart: false,
          child: ListView.builder(
            itemBuilder: (context, index) {
              if (index == 0)
                return ListTile(
                  title: Text(I18n.of(context).all),
                  onPressed: () {
                    Navigator.pop(context, {
                      "tag": null,
                      "restrict": widget.restrict,
                    });
                  },
                );
              else if (index == 1)
                return ListTile(
                  title: Text(I18n.of(context).unclassified),
                  onPressed: () {
                    Navigator.pop(context, {
                      "tag": "未分類",
                      "restrict": widget.restrict,
                    }); //日语
                  },
                );
              else if (index == 2 &&
                  _bookMarkTagStore.bookmarkTags.isEmpty &&
                  _bookMarkTagStore.fetchFailed.value)
                return ListTile(
                  leading: const Icon(FluentIcons.refresh),
                  title: Text(I18n.of(context).loading_failed_retry_message),
                  onPressed: () => _bookMarkTagStore.fetch(widget.restrict),
                );
              var bookmarkTag = _bookMarkTagStore.bookmarkTags[index - 2];
              return ListTile(
                title: Text(bookmarkTag.name),
                trailing: Text(bookmarkTag.count.toString()),
                onPressed: () {
                  Navigator.pop(context, {
                    "tag": bookmarkTag.name,
                    "restrict": widget.restrict,
                  });
                },
              );
            },
            itemCount:
                _bookMarkTagStore.bookmarkTags.length +
                2 +
                (_bookMarkTagStore.bookmarkTags.isEmpty &&
                        _bookMarkTagStore.fetchFailed.value
                    ? 1
                    : 0),
          ),
          onRefresh: () async {
            await _bookMarkTagStore.fetch(widget.restrict);
          },
          onLoad: () async {
            await _bookMarkTagStore.next();
          },
        );
      },
    );
  }
}
