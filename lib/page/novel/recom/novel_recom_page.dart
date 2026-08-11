/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 */

import 'package:flutter/material.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/page/novel/component/novel_lighting_list.dart';

class NovelRecomPage extends StatefulWidget {
  const NovelRecomPage({super.key});

  @override
  State<NovelRecomPage> createState() => _NovelRecomPageState();
}

class _NovelRecomPageState extends State<NovelRecomPage>
    with AutomaticKeepAliveClientMixin {
  late final FutureGet _futureGet;

  @override
  void initState() {
    super.initState();
    _futureGet = apiClient.getNovelRecommended;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(title: Text(I18n.of(context).recommend)),
      body: NovelLightingList(futureGet: _futureGet),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
