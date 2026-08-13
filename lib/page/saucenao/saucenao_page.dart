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

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/page/picture/illust_lighting_page.dart';
import 'package:pixez/page/saucenao/sauce_store.dart';

class SauceNaoPage extends StatefulWidget {
  final String? path;

  const SauceNaoPage({Key? key, this.path}) : super(key: key);

  @override
  _SauceNaoPageState createState() => _SauceNaoPageState();
}

class _SauceNaoPageState extends State<SauceNaoPage> {
  SauceStore _store = SauceStore();
  StreamSubscription<SauceSearchEvent>? _sauceSubscription;

  @override
  void dispose() {
    _sauceSubscription?.cancel();
    _store.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _sauceSubscription = _store.observableStream.listen((event) {
      if (!mounted) return;
      if (event.illustIds.isNotEmpty) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => PageView(
              children: event.illustIds
                  .map((element) => IllustLightingPage(id: element))
                  .toList(),
            ),
          ),
        );
      }
    });
    if (widget.path != null) {
      _store.findImage(context: context, path: widget.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        child: Icon(Icons.add_photo_alternate),
        backgroundColor: Theme.of(context).colorScheme.secondary,
        onPressed: () {
          _store.findImage(context: context);
        },
      ),
      appBar: AppBar(title: Icon(Icons.dashboard)),
      body: Container(
        child: ListView(
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16.0),
                child: Center(child: Text('SauceNao')),
              ),
            ),
            Observer(
              builder: (_) {
                final phase = _store.phase.value;
                if (phase.isBusy) {
                  final label = phase == SauceSearchPhase.uploading
                      ? I18n.of(context).uploading
                      : I18n.of(context).parsing;
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          const LinearProgressIndicator(),
                          const SizedBox(height: 12),
                          Text(label),
                        ],
                      ),
                    ),
                  );
                }
                if (phase == SauceSearchPhase.error) {
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.error_outline),
                      title: Text(_store.lastError.value ?? 'Search failed'),
                    ),
                  );
                }
                if (phase == SauceSearchPhase.noResult) {
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.search_off),
                      title: Text(I18n.of(context).no_result),
                    ),
                  );
                }
                if (_store.notStart) {
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(widget.path ?? ""),
                    ),
                  );
                }
                return InkWell(
                  child: Card(
                    child: _store.results.isNotEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text(
                              I18n.of(context).tap_to_show_results(
                                _store.results.length.toString(),
                              ),
                            ),
                          )
                        : Container(
                            child: Image.asset('assets/images/nine.jpg'),
                          ),
                  ),
                  onTap: () {
                    if (_store.results.isNotEmpty) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => PageView(
                            children: _store.results
                                .map(
                                  (element) => IllustLightingPage(id: element),
                                )
                                .toList(),
                          ),
                        ),
                      );
                    }
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
