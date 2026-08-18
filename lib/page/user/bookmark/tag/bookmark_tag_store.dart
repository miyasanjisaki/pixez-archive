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
import 'package:mobx/mobx.dart';
import 'package:pixez/models/illust_bookmark_tags_response.dart';
import 'package:pixez/network/api_client.dart';
part 'bookmark_tag_store.g.dart';

class BookMarkTagStore = _BookMarkTagStoreBase with _$BookMarkTagStore;

abstract class _BookMarkTagStoreBase with Store {
  ObservableList<BookmarkTag> bookmarkTags = ObservableList();
  final EasyRefreshController _controller;
  final int id;
  String? nextUrl;
  final Observable<bool> fetchFailed = Observable(false);
  int _generation = 0;
  bool _loadingNext = false;

  _BookMarkTagStoreBase(this.id, this._controller);

  List<BookmarkTag> _deduplicate(Iterable<BookmarkTag> tags) {
    final byName = <String, BookmarkTag>{};
    for (final tag in tags) {
      byName[tag.name] = tag;
    }
    return byName.values.toList(growable: false);
  }

  @action
  fetch(String restrict) async {
    final generation = ++_generation;
    nextUrl = null;
    fetchFailed.value = false;
    _loadingNext = false;
    _controller.resetFooter();
    try {
      final result = await apiClient.getUserBookmarkTagsIllust(
        id,
        restrict: restrict,
        force: true,
      );
      if (generation != _generation) return;
      nextUrl = result.nextUrl;
      bookmarkTags.clear();
      bookmarkTags.addAll(_deduplicate(result.bookmarkTags));
      _controller.finishRefresh(IndicatorResult.success);
      _controller.resetFooter();
    } catch (_) {
      if (generation != _generation) return;
      fetchFailed.value = true;
      _controller.finishRefresh(IndicatorResult.fail);
    }
  }

  @action
  next() async {
    if (_loadingNext) return;
    if (nextUrl != null && nextUrl!.isNotEmpty) {
      final generation = _generation;
      final requestedUrl = nextUrl!;
      _loadingNext = true;
      try {
        final result = await apiClient.getNext(requestedUrl);
        if (generation != _generation) return;
        final r = IllustBookmarkTagsResponse.fromJson(result.data);
        nextUrl = r.nextUrl;
        final mergedTags = _deduplicate([...bookmarkTags, ...r.bookmarkTags]);
        bookmarkTags
          ..clear()
          ..addAll(mergedTags);
        _controller.finishLoad(
          nextUrl == null ? IndicatorResult.noMore : IndicatorResult.success,
        );
      } catch (_) {
        if (generation != _generation) return;
        _controller.finishLoad(IndicatorResult.fail);
      } finally {
        if (generation == _generation) {
          _loadingNext = false;
        }
      }
    } else {
      _controller.finishLoad(IndicatorResult.noMore);
    }
  }
}
