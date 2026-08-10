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

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/main.dart';
import 'package:pixez/page/picture/illust_lighting_page.dart';
import 'package:pixez/page/picture/illust_store.dart';

class PictureListPage extends StatefulWidget {
  final IllustStore store;
  final List<IllustStore> iStores;
  final List<IllustStore> Function()? iStoresProvider;
  final String? heroString;
  final LightingStore? lightingStore;

  const PictureListPage(
      {Key? key,
      required this.lightingStore,
      required this.store,
      required this.iStores,
      this.iStoresProvider,
      this.heroString})
      : super(key: key);

  @override
  _PictureListPageState createState() => _PictureListPageState();
}

class _PictureListPageState extends State<PictureListPage> {
  late PageController _pageController;
  late int nowPosition;
  late LightingStore? _lightingStore;
  late List<IllustStore> _iStores;
  late IllustStore _store;
  double screenWidth = 0;

  @override
  void initState() {
    _store = widget.store;
    _iStores = widget.iStoresProvider == null
        ? widget.iStores
        : List<IllustStore>.of(widget.iStores);
    _lightingStore = widget.lightingStore;
    nowPosition = _iStores.indexOf(_store);
    _pageController = PageController(initialPage: nowPosition);
    super.initState();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    screenWidth = MediaQuery.of(context).size.width / 2;
    return Observer(builder: (_) {
      final iStores = _currentStores;
      return MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(gestureSettings: DeviceGestureSettings(touchSlop: 50)),
        child: PageView.builder(
          controller: _pageController,
          physics: userSetting.swipeChangeArtwork
              ? null
              : NeverScrollableScrollPhysics(),
          itemBuilder: (BuildContext context, int index) {
            if (index == iStores.length && _lightingStore != null) {
              return PictureListNextPage(
                lightingStore: _lightingStore!,
              );
            }
            final f = iStores[index];
            String? tag = nowPosition == index ? widget.heroString : null;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  gestureSettings:
                      DeviceGestureSettings(touchSlop: kTouchSlop)),
              child: IllustLightingPage(
                id: f.id,
                heroString: tag,
                store: f,
                onHorizontalDragEnd: (details) {
                  _onDrag(details);
                },
              ),
            );
          },
          itemCount: iStores.length + (_lightingStore == null ? 0 : 1),
        ),
      );
    });
  }

  List<IllustStore> get _currentStores {
    final provider = widget.iStoresProvider;
    if (provider == null) return _iStores;

    final knownIds = _iStores.map((store) => store.id).toSet();
    for (final store in provider()) {
      if (knownIds.add(store.id)) _iStores.add(store);
    }
    return _iStores;
  }

  _onDrag(DragEndDetails details) {
    final iStores = _currentStores;
    final pixelsPerSecond = details.velocity.pixelsPerSecond;
    if (pixelsPerSecond.dy.abs() > pixelsPerSecond.dx.abs()) return;
    if (pixelsPerSecond.dx.abs() > screenWidth) {
      int result = nowPosition;
      if (pixelsPerSecond.dx < 0)
        result++;
      else
        result--;
      _pageController.animateToPage(result,
          duration: Duration(milliseconds: 200), curve: Curves.easeInOut);
      if (result >= iStores.length) result = iStores.length - 1;
      if (result < 0) result = 0;
      setState(() {
        nowPosition = result;
      });
    }
  }
}

class PictureListNextPage extends StatefulWidget {
  final LightingStore lightingStore;
  const PictureListNextPage({super.key, required this.lightingStore});

  @override
  State<PictureListNextPage> createState() => _PictureListNextPageState();
}

class _PictureListNextPageState extends State<PictureListNextPage> {
  late LightingStore _lightingStore;
  bool? loadResult;
  @override
  void initState() {
    _lightingStore = widget.lightingStore;
    super.initState();
    _maybeFetch(true);
  }

  _maybeFetch(bool firstIn) async {
    if (_lightingStore.nextUrl?.isNotEmpty != true) return;
    try {
      if (!firstIn) {
        setState(() {
          loadResult = null;
        });
      }
      final result = await _lightingStore.fetchNext();
      if (mounted) {
        setState(() {
          loadResult = result;
        });
      }
    } catch (e) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_lightingStore.nextUrl?.isNotEmpty != true) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text("No More")),
      );
    }
    if (loadResult == false) {
      return Scaffold(
        appBar: AppBar(),
        body: Container(
            child: Center(
          child: Column(children: [
            Text("Load Failed"),
            TextButton(
                onPressed: () {
                  _maybeFetch(false);
                },
                child: Text("Retry"))
          ]),
        )),
      );
    }
    if (loadResult == true) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: TextButton(
            onPressed: () => _maybeFetch(false),
            child: Text(I18n.of(context).more),
          ),
        ),
      );
    }
    return Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}
