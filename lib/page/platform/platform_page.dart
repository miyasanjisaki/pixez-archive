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

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pixez/document_plugin.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/open_setting_plugin.dart';
import 'package:pixez/page/directory/save_mode_choice_page.dart';
import 'package:pixez/page/hello/setting/save_eval_page.dart';
import 'package:pixez/page/hello/setting/save_format_page.dart';
import 'package:pixez/utils/display_mode_selection.dart';

class PlatformPage extends StatefulWidget {
  @override
  _PlatformPageState createState() => _PlatformPageState();
}

class _PlatformPageState extends State<PlatformPage> {
  String path = "";
  List<DisplayMode> modes = <DisplayMode>[];
  DisplayMode? selected;
  DisplayMode? active;

  @override
  void initState() {
    super.initState();
    initVoid();
  }

  Future<void> fetchModes() async {
    try {
      final modeList = await FlutterDisplayMode.supported;
      final activeMode = await FlutterDisplayMode.active;

      /// On OnePlus 7 Pro:
      /// #1 1080x2340 @ 60Hz
      /// #2 1080x2340 @ 90Hz
      /// #3 1440x3120 @ 90Hz
      /// #4 1440x3120 @ 60Hz

      /// On OnePlus 8 Pro:
      /// #1 1080x2376 @ 60Hz
      /// #2 1440x3168 @ 120Hz
      /// #3 1440x3168 @ 60Hz
      /// #4 1080x2376 @ 120Hz
      final preferred = userSetting.displayModeAutomatic
          ? modeList.cast<DisplayMode?>().firstWhere(
              (mode) => mode?.id == 0,
              orElse: () => null,
            )
          : await FlutterDisplayMode.preferred;
      if (!mounted) return;
      setState(() {
        modes = modeList;
        selected = preferred;
        active = activeMode;
      });
      await userSetting.refreshDisplayModeDiagnostics();
    } on PlatformException catch (e) {
      print(e);

      /// e.code =>
      /// noAPI - No API support. Only Marshmallow and above.
      /// noActivity - Activity is not available. Probably app is in background
    }
    // if (mounted) {
    //   setState(() {});
    // }
  }

  Future<void> initVoid() async {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        version = packageInfo.version;
      });
    }
    await fetchModes();
    String path = (await DocumentPlugin.getPath())!;
    if (mounted) {
      setState(() {
        this.path = path;
      });
    }
    var androidInfo = await DeviceInfoPlugin().androidInfo;
    if (mounted) {
      setState(() {
        _androidInfo = androidInfo;
      });
    }
  }

  AndroidDeviceInfo? _androidInfo;

  String version = "";
  bool singleFolder = false;

  Future<void> _showDisplayModeDiagnostics() async {
    await userSetting.refreshDisplayModeDiagnostics(
      reason: 'advanced-settings',
    );
    try {
      final activeMode = await FlutterDisplayMode.active;
      if (mounted) {
        setState(() {
          active = activeMode;
        });
      }
    } on PlatformException {
      // The safe report will show an unknown rate when Android cannot provide
      // the current mode. Never expose the raw platform exception to the UI.
    }
    if (!mounted) return;

    final isChinese = Localizations.localeOf(context).languageCode == 'zh';
    final report = buildSafeDisplayModeDiagnosticReport(
      automatic: userSetting.displayModeAutomatic,
      activeRefreshRate: active?.refreshRate,
      nativeDiagnostics: userSetting.displayModeDiagnostics,
      chinese: isChinese,
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isChinese ? '高级诊断' : 'Advanced diagnostics'),
        content: SingleChildScrollView(child: SelectableText(report)),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (!dialogContext.mounted) return;
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                SnackBar(
                  content: Text(
                    isChinese ? '诊断摘要已复制' : 'Diagnostic summary copied',
                  ),
                ),
              );
            },
            child: Text(isChinese ? '复制诊断' : 'Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(isChinese ? '关闭' : 'Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ListTile(
          title: Text("Platform Setting"),
          subtitle: Text(
            "For Android",
            style: TextStyle(color: Colors.greenAccent),
          ),
        ),
      ),
      body: Container(
        child: Observer(
          builder: (_) {
            return ListView(
              children: <Widget>[
                ListTile(
                  leading: Icon(Icons.folder),
                  title: Text(
                    '${I18n.of(context).save_path}(${userSetting.saveMode != 0 ? (userSetting.saveMode == 2 ? I18n.of(context).old_way : 'SAF') : "Media"})',
                  ),
                  subtitle: Text(path),
                  onTap: () async {
                    await showPathDialog(context);
                    final path = await DocumentPlugin.getPath();
                    if (mounted) {
                      setState(() {
                        this.path = path!;
                      });
                    }
                  },
                ),
                ListTile(
                  leading: Icon(Icons.format_align_left),
                  title: Text(I18n.of(context).save_format),
                  subtitle: Text(
                    userSetting.fileNameEval == 1
                        ? "Eval"
                        : userSetting.format ?? "",
                  ),
                  onTap: () async {
                    if (userSetting.fileNameEval == 1) {
                      Leader.push(context, SaveEvalPage());
                    } else {
                      final result =
                          await Navigator.of(context, rootNavigator: true).push(
                            MaterialPageRoute(
                              builder: (context) => SaveFormatPage(),
                            ),
                          );
                      if (result is String) {
                        userSetting.setFormat(result);
                      }
                    }
                    // if (result != null) userSetting.setPath(result);
                  },
                  trailing: InkWell(
                    onTap: () {
                      Leader.push(context, SaveEvalPage());
                    },
                    child: Container(
                      margin: EdgeInsets.all(8),
                      child: userSetting.fileNameEval == 1
                          ? Text(
                              "Script",
                              style: TextStyle(
                                color: Theme.of(context).primaryColor,
                              ),
                            )
                          : Text("Script"),
                    ),
                  ),
                ),
                Observer(
                  builder: (context) {
                    return SwitchListTile(
                      secondary: Icon(Icons.folder_shared),
                      onChanged: (bool value) async {
                        if (value) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("可能会造成保存等待时间过长")),
                          );
                        }
                        await userSetting.setSingleFolder(value);
                      },
                      title: Text(I18n.of(context).separate_folder),
                      subtitle: Text(I18n.of(context).separate_folder_message),
                      value: userSetting.singleFolder,
                    );
                  },
                ),
                Observer(
                  builder: (context) {
                    return SwitchListTile(
                      secondary: Icon(Icons.folder_open),
                      onChanged: (bool value) async {
                        await userSetting.setOverSanityLevelFolder(value);
                      },
                      title: Text("Sanity Single Folder"),
                      value: userSetting.overSanityLevelFolder,
                    );
                  },
                ),
                ListTile(
                  leading: Icon(Icons.mobile_screen_share),
                  onTap: () {
                    showModalBottomSheet(
                      context: context,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(8.0),
                        ),
                      ),
                      builder: (_) {
                        return SafeArea(
                          child: Container(
                            child: modes.isNotEmpty
                                ? ListView.builder(
                                    shrinkWrap: true,
                                    itemCount: modes.length + 1,
                                    itemBuilder: (context, index) {
                                      if (index == 0)
                                        return ListTile(
                                          title: Text(
                                            I18n.of(
                                              context,
                                            ).display_mode_message,
                                          ),
                                          subtitle: Text(
                                            I18n.of(
                                              context,
                                            ).display_mode_warning,
                                          ),
                                          onTap: () async {},
                                        );
                                      final mode = modes[index - 1];
                                      return ListTile(
                                        title: Text(
                                          mode.id == 0
                                              ? 'Automatic (highest refresh rate)'
                                              : '${formatRefreshRate(mode.refreshRate)} Hz',
                                        ),
                                        subtitle: mode.id == 0
                                            ? const Text(
                                                'Keep the active resolution and prefer its highest refresh rate.',
                                              )
                                            : Text(
                                                '${mode.width} × ${mode.height}',
                                              ),
                                        trailing:
                                            (mode.id == 0 &&
                                                    userSetting
                                                        .displayModeAutomatic) ||
                                                (mode.id != 0 &&
                                                    !userSetting
                                                        .displayModeAutomatic &&
                                                    selected?.id == mode.id)
                                            ? const Icon(Icons.check)
                                            : null,
                                        onTap: () async {
                                          await userSetting.setDisplayMode(
                                            mode.id == 0 ? null : mode,
                                          );
                                          await fetchModes();
                                          if (!context.mounted) return;
                                          Navigator.of(context).pop();
                                        },
                                      );
                                    },
                                  )
                                : Container(),
                          ),
                        );
                      },
                    );
                  },
                  title: Text(I18n.of(context).display_mode),
                  subtitle: Text(
                    displayModeUserSummary(
                      automatic: userSetting.displayModeAutomatic,
                      activeRefreshRate: active?.refreshRate,
                      selectedRefreshRate: selected?.refreshRate,
                      chinese:
                          Localizations.localeOf(context).languageCode == 'zh',
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.monitor_heart_outlined),
                  title: Text(
                    Localizations.localeOf(context).languageCode == 'zh'
                        ? '高级诊断'
                        : 'Advanced diagnostics',
                  ),
                  subtitle: Text(
                    Localizations.localeOf(context).languageCode == 'zh'
                        ? '仅显示刷新率与高刷请求状态'
                        : 'Refresh-rate request status only',
                  ),
                  onTap: _showDisplayModeDiagnostics,
                ),
                if ((_androidInfo?.version.sdkInt ?? 0) > 30) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      "More for Android 12",
                      style: TextStyle(color: Colors.green),
                    ),
                  ),
                  ListTile(
                    leading: Icon(Icons.add_link),
                    title: Text(I18n.of(context).open_by_default),
                    subtitle: Text(I18n.of(context).open_by_default_subtitle),
                    onTap: () {
                      OpenSettingPlugin.open();
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 100.0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.asset(
                        "assets/images/open_by_default_hint.png",
                      ),
                    ),
                  ),
                  Container(height: 20),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
