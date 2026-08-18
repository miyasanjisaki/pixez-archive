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

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/component/new_version_chip.dart';
import 'package:pixez/constants.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/page/about/update_page.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';

class AboutPage extends StatefulWidget {
  final bool? newVersion;

  const AboutPage({Key? key, this.newVersion}) : super(key: key);

  @override
  _AboutPageState createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const _archiveRepositoryUrl =
      'https://github.com/miyasanjisaki/pixez-archive';
  static const _upstreamRepositoryUrl =
      'https://github.com/Notsfsssf/pixez-flutter';
  static const _archiveIssuesUrl =
      'https://github.com/miyasanjisaki/pixez-archive/issues';
  static const _feedbackEmail = '429230857@qq.com';

  late bool hasNewVersion;

  @override
  void initState() {
    hasNewVersion = widget.newVersion ?? false;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: Scaffold(
        appBar: AppBar(
          title: Text(I18n.of(context).about),
          actions: <Widget>[],
        ),
        body: _buildInfo(context),
      ),
    );
  }

  Widget _buildInfo(BuildContext context) {
    return Observer(
      builder: (context) {
        return ListView(
          children: <Widget>[
            ListTile(
              leading: CircleAvatar(
                backgroundImage: AssetImage('assets/images/me.jpg'),
              ),
              title: Text('Perol_Notsfsssf'),
              subtitle: Text(I18n.of(context).perol_message),
              onTap: () {
                showModalBottomSheet(
                  context: context,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  builder: (BuildContext context) {
                    return InkWell(
                      onTap: () {
                        if (Platform.isAndroid)
                          launchUrlString(
                            Constants.isGooglePlay
                                ? "https://music.youtube.com/watch?v=qfDhiBUNzwA&feature=share"
                                : "https://music.apple.com/cn/album/intrauterine-education-single/1515096587",
                          );
                      },
                      child: Container(
                        child: Image.asset(
                          'assets/images/liz.png',
                          fit: BoxFit.cover,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
            ListTile(
              leading: CircleAvatar(
                backgroundImage: NetworkImage(
                  'https://github.com/miyasanjisaki.png',
                ),
              ),
              title: Text('miyasanjisaki'),
              subtitle: Text(I18n.of(context).archive_maintainer_message),
              trailing: Icon(Icons.open_in_new),
              onTap: () async {
                try {
                  await launchUrlString(_archiveRepositoryUrl);
                } catch (_) {}
              },
            ),
            ListTile(
              leading: Icon(Icons.rate_review),
              title: Text(I18n.of(context).rate_title),
              subtitle: Text(I18n.of(context).rate_message),
              onTap: () async {
                if (Platform.isIOS) {
                  var url = 'https://apps.apple.com/cn/app/pixez/id1494435126';
                  try {
                    await launchUrlString(url);
                  } catch (e) {}
                }
              },
            ),
            if (Platform.isAndroid || kDebugMode) ...[
              ListTile(
                leading: Icon(Icons.device_hub),
                title: Text(I18n.of(context).repo_address),
                subtitle: Text('github.com/miyasanjisaki/pixez-archive'),
                trailing: Visibility(
                  child: NewVersionChip(),
                  visible: hasNewVersion,
                ),
                onTap: () {
                  if (!Constants.isGooglePlay)
                    showModalBottomSheet(
                      context: context,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(16.0),
                        ),
                      ),
                      builder: (_) {
                        return SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              ListTile(
                                title: Text('Version ${Constants.tagName}'),
                                subtitle: Text(
                                  I18n.of(context).go_to_project_address,
                                ),
                                onTap: () {
                                  try {
                                    launchUrlString(_archiveRepositoryUrl);
                                  } catch (e) {}
                                },
                                trailing: IconButton(
                                  icon: Icon(Icons.link),
                                  onPressed: () {
                                    try {
                                      launchUrlString(_archiveRepositoryUrl);
                                    } catch (e) {}
                                  },
                                ),
                              ),
                              ListTile(
                                leading: Icon(Icons.fork_right),
                                title: Text('PixEz Flutter upstream'),
                                subtitle: Text(
                                  'github.com/Notsfsssf/pixez-flutter',
                                ),
                                trailing: Icon(Icons.open_in_new),
                                onTap: () async {
                                  try {
                                    await launchUrlString(
                                      _upstreamRepositoryUrl,
                                    );
                                  } catch (_) {}
                                },
                              ),
                              ListTile(
                                title: Text(I18n.of(context).check_for_updates),
                                onTap: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => UpdatePage(),
                                    ),
                                  );
                                },
                                trailing: Icon(Icons.update),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                },
              ),
            ],
            ListTile(
              leading: Icon(Icons.email),
              title: Text(I18n.of(context).feedback),
              subtitle: Text(_feedbackEmail),
              onTap: () async {
                try {
                  await launchUrlString('mailto:$_feedbackEmail');
                } catch (_) {}
              },
            ),
            ListTile(
              leading: Icon(Icons.stars),
              title: Text(I18n.of(context).support),
              subtitle: Text('PixEz Archive 项目与问题反馈'),
              onTap: () async {
                try {
                  await launchUrlString(_archiveIssuesUrl);
                } catch (_) {}
              },
            ),
            ListTile(
              leading: Icon(Icons.favorite),
              title: Text(I18n.of(context).thanks),
              subtitle: Text('感谢上游 PixEz 的作者与贡献者\n感谢 pixiv.cat 提供的图床'),
              onTap: () async {
                try {
                  await launchUrlString(_upstreamRepositoryUrl);
                } catch (_) {}
              },
            ),
            ListTile(
              leading: Icon(Icons.share),
              title: Text(I18n.of(context).share),
              subtitle: Text('分享我的 GitHub 项目'),
              onTap: () {
                SharePlus.instance.share(
                  ShareParams(text: _archiveRepositoryUrl),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
