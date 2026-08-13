/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 */

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/component/pixez_default_header.dart';
import 'package:pixez/exts.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/page/novel/component/novel_card.dart';
import 'package:pixez/page/novel/component/novel_lighting_store.dart';
import 'package:pixez/page/novel/viewer/novel_store.dart';
import 'package:pixez/page/novel/viewer/novel_viewer.dart';
import 'package:pixez/utils/novel_result_options.dart';
import 'package:pixez/utils/result_sort.dart';

class NovelLightingList extends StatefulWidget {
  final FutureGet futureGet;
  final bool? isNested;
  final bool showSortControls;

  const NovelLightingList({
    super.key,
    required this.futureGet,
    this.isNested,
    this.showSortControls = true,
  });

  @override
  State<NovelLightingList> createState() => _NovelLightingListState();
}

class _NovelLightingListState extends State<NovelLightingList> {
  late EasyRefreshController _easyRefreshController;
  late NovelLightingStore _store;
  late bool _isNested;
  NovelResultSort _resultSort = NovelResultSort.apiOrder;

  @override
  void initState() {
    _isNested = widget.isNested ?? false;
    _easyRefreshController = EasyRefreshController(
      controlFinishLoad: true,
      controlFinishRefresh: true,
    );
    _store = NovelLightingStore(widget.futureGet, _easyRefreshController);
    super.initState();
    if (_isNested) _store.fetch();
  }

  @override
  void didUpdateWidget(NovelLightingList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.futureGet != widget.futureGet) {
      _store.source = widget.futureGet;
      _easyRefreshController.resetFooter();
      _store.fetch();
    }
  }

  @override
  void dispose() {
    _easyRefreshController.dispose();
    super.dispose();
  }

  List<NovelStore> _visibleStores() {
    final comparator = buildNovelResultComparator<NovelStore>(
      _resultSort,
      bookmarksOf: (store) => store.novel!.totalBookmarks,
      viewsOf: (store) => store.novel!.totalView,
    );
    return stableSortedCopy(
      _store.novels.where(
        (store) => store.novel != null && store.novel?.hateByUser() != true,
      ),
      comparator,
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_store.errorMessage != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.65,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(':(', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: _store.fetch,
                    child: Text(I18n.of(context).retry),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '${_store.errorMessage}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return _buildListBody(context);
  }

  Widget _buildListBody(BuildContext context) {
    final visibleStores = _visibleStores();
    final headerCount = widget.showSortControls ? 1 : 0;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: visibleStores.length + headerCount,
      itemBuilder: (context, index) {
        if (widget.showSortControls && index == 0) {
          return _buildSortControls(context);
        }
        final store = visibleStores[index - headerCount];
        final novel = store.novel!;
        return NovelCard(
          key: ValueKey(novel.id),
          novel: novel,
          resultSort: _resultSort,
          onTap: () {
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (context) =>
                    NovelViewerPage(id: novel.id, novelStore: store),
              ),
            );
          },
        );
      },
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
                  context,
                  value: NovelResultSort.apiOrder,
                  label: I18n.of(context).pixiv_sort,
                  icon: Icons.format_list_numbered,
                ),
                const SizedBox(width: 8),
                _sortChip(
                  context,
                  value: NovelResultSort.bookmarksDesc,
                  label: I18n.of(context).novel_bookmarks,
                  icon: Icons.bookmark_outline,
                ),
                const SizedBox(width: 8),
                _sortChip(
                  context,
                  value: NovelResultSort.viewsDesc,
                  label: I18n.of(context).novel_views,
                  icon: Icons.visibility_outlined,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sortChip(
    BuildContext context, {
    required NovelResultSort value,
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

  @override
  Widget build(BuildContext context) {
    return EasyRefresh(
      onLoad: _store.next,
      onRefresh: _store.fetch,
      refreshOnStart: !_isNested,
      controller: _easyRefreshController,
      header: PixezDefault.header(context),
      child: Observer(builder: (context) => _buildBody(context)),
    );
  }
}
