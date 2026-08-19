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
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        compute,
        debugPrint,
        debugPrintStack,
        defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pixez/document_plugin.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/download_identity_index.dart';
import 'package:pixez/models/task_persist.dart';
import 'package:pixez/open_setting_plugin.dart';
import 'package:pixez/page/directory/save_mode_choice_page.dart';
import 'package:pixez/page/hello/setting/save_eval_page.dart';
import 'package:pixez/page/hello/setting/save_format_page.dart';
import 'package:pixez/utils/display_mode_selection.dart';
import 'package:pixez/utils/download_identity_backfill.dart';

class PlatformPage extends StatefulWidget {
  @override
  _PlatformPageState createState() => _PlatformPageState();
}

class _PlatformPageState extends State<PlatformPage> {
  String path = "";
  List<DisplayMode> modes = <DisplayMode>[];
  DisplayMode? selected;
  DisplayMode? active;
  bool _backfillRunning = false;
  bool _backfillCancelRequested = false;
  int _backfillProcessed = 0;
  int _backfillTotal = 0;
  int _backfillIndexed = 0;

  @override
  void initState() {
    super.initState();
    initVoid();
  }

  @override
  void dispose() {
    _backfillCancelRequested = true;
    super.dispose();
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

  Future<void> _startDownloadIdentityBackfill() async {
    final isChinese = Localizations.localeOf(context).languageCode == 'zh';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isChinese ? '重建旧下载识图索引' : 'Rebuild image identity index'),
        content: Text(
          isChinese
              ? '将读取当前 PixEz 保存目录中的图片，在本机计算 SHA-256 与 dHash，并与旧下载记录或标准 Pixiv 文件名对应。不会上传图片。最多处理 4096 张；目录扫描后会显示进度，指纹计算阶段可取消。'
              : 'PixEz will read images from the current save folder, compute SHA-256 and dHash locally, and associate them with completed downloads or canonical Pixiv filenames. No image is uploaded. Up to 4096 images are processed; progress appears after directory scanning and fingerprinting can be cancelled.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(isChinese ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isChinese ? '开始' : 'Start'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    if (userSetting.saveMode != 1) {
      var granted = false;
      try {
        granted = await DocumentPlugin.permissionStatus() ?? false;
        if (!granted) {
          granted = await DocumentPlugin.requestPermission() ?? false;
        }
      } on PlatformException {
        granted = false;
      }
      if (!mounted) return;
      if (!granted) {
        final chooseSaveMode = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(isChinese ? '需要读取图片权限' : 'Photo access is required'),
            content: Text(
              isChinese
                  ? '要扫描旧版或重新安装前保存的图片，需要允许读取图片。如果不想授予整体图片权限，可将保存模式切换为 SAF，只授权 PixEz 保存目录。'
                  : 'Scanning images saved by an older installation requires photo access. You can instead switch the save mode to SAF and authorize only the PixEz save folder.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(isChinese ? '取消' : 'Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(isChinese ? '选择保存模式' : 'Choose save mode'),
              ),
            ],
          ),
        );
        if (chooseSaveMode == true && mounted) {
          await showPathDialog(context);
          if (mounted) {
            final selectedPath = await DocumentPlugin.getPath();
            if (mounted && selectedPath != null) {
              setState(() {
                path = selectedPath;
              });
            }
          }
        }
        return;
      }
    }

    setState(() {
      _backfillRunning = true;
      _backfillCancelRequested = false;
      _backfillProcessed = 0;
      _backfillTotal = 0;
      _backfillIndexed = 0;
    });

    try {
      final savedImages = await DocumentPlugin.listSavedImages(
        maximumCount: defaultBackfillMaximumCandidates + 1,
        maximumDepth: 8,
      );
      List<TaskPersist> tasks;
      try {
        tasks = await fetcher.taskPersistProvider.getAllAccount();
      } catch (_) {
        await fetcher.taskPersistProvider.open();
        tasks = await fetcher.taskPersistProvider.getAllAccount();
      }
      final plan = planDownloadIdentityBackfill(
        savedImages: savedImages
            .take(defaultBackfillMaximumCandidates)
            .map(
              (image) => SavedImageBackfillReference(
                token: image.token,
                displayName: image.displayName,
                relativePath: image.relativePath,
                byteLength: image.byteLength,
              ),
            ),
        sourceTruncated: savedImages.length > defaultBackfillMaximumCandidates,
        completedDownloads: tasks
            .where((task) => task.status == 2 && task.illustId > 0)
            .map(
              (task) => CompletedDownloadBackfillReference(
                illustId: task.illustId,
                fileName: task.fileName,
                sourceUrl: task.url,
              ),
            ),
      );
      if (mounted) {
        setState(() {
          _backfillTotal = plan.candidates.length;
        });
      }

      var lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
      final summary = await runDownloadIdentityBackfill(
        plan: plan,
        readImage: (image) => DocumentPlugin.readSavedImage(
          image.token,
          maximumBytes: defaultBackfillMaximumImageBytes,
        ),
        computeFingerprints: (bytes) =>
            compute(computeDownloadImageFingerprints, bytes),
        rememberIdentity: (candidate, fingerprints) async {
          final existing = await downloadIdentityIndex.findDigest(
            fingerprints['sha256']!,
          );
          if (existing != null &&
              (existing.illustId != candidate.illustId ||
                  existing.pageIndex != candidate.pageIndex)) {
            return false;
          }
          await downloadIdentityIndex.rememberDigest(
            sha256: fingerprints['sha256']!,
            illustId: candidate.illustId,
            pageIndex: candidate.pageIndex,
            fileName: candidate.image.displayName,
            differenceHash: fingerprints['dhash'],
          );
          return true;
        },
        shouldCancel: () => _backfillCancelRequested,
        abortOnError: (error) =>
            error is PlatformException &&
            const <String>{
              'MEDIA_READ_PERMISSION_REQUIRED',
              'SAF_PERMISSION_MISSING',
              'SAF_ROOT_INVALID',
              'SAVE_ROOT_INVALID',
              'SAVE_ROOT_MISSING',
              'SAVE_ROOT_UNREADABLE',
              'SAVED_IMAGE_PERMISSION_REVOKED',
              'SAVED_IMAGE_SCAN_EXPIRED',
              'SAVED_IMAGE_TOKEN_INVALID',
              'SAVED_IMAGE_TOKEN_STALE',
            }.contains(error.code),
        onProgress: (progress) {
          final now = DateTime.now();
          if (progress.processed != progress.total &&
              now.difference(lastUiUpdate).inMilliseconds < 120) {
            return;
          }
          lastUiUpdate = now;
          if (!mounted) return;
          setState(() {
            _backfillProcessed = progress.processed;
            _backfillTotal = progress.total;
            _backfillIndexed = progress.indexed;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _backfillProcessed = summary.processed;
        _backfillTotal = summary.total;
        _backfillIndexed = summary.indexed;
      });
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            summary.cancelled
                ? (isChinese ? '已取消' : 'Cancelled')
                : (isChinese ? '索引重建完成' : 'Index rebuilt'),
          ),
          content: Text(
            isChinese
                ? '成功加入索引：${summary.indexed}\n读取失败：${summary.failed}\n跳过文件：${summary.skipped}\n无法从文件名或旧任务确定来源：${plan.unidentifiedCount}\n证据冲突：${plan.ambiguousCount}\n文件过大：${plan.oversizedCount}${plan.truncated ? '\n已达到 4096 张上限' : ''}'
                : 'Indexed: ${summary.indexed}\nRead failures: ${summary.failed}\nSkipped files: ${summary.skipped}\nNo source in filename or completed task: ${plan.unidentifiedCount}\nConflicting evidence: ${plan.ambiguousCount}\nOversized files: ${plan.oversizedCount}${plan.truncated ? '\nThe 4096 image limit was reached.' : ''}',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(isChinese ? '确定' : 'OK'),
            ),
          ],
        ),
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(isChinese ? '无法读取保存目录' : 'Save folder unavailable'),
          content: Text(
            isChinese
                ? '请确认 PixEz 对当前保存目录仍有读取权限。\n${error.code}'
                : 'Check that PixEz still has read access to the current save folder.\n${error.code}',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(isChinese ? '确定' : 'OK'),
            ),
          ],
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Unable to rebuild old download image index: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(isChinese ? '索引重建失败' : 'Index rebuild failed'),
          content: Text(
            isChinese
                ? '未更改原图，已写入的索引仍然可用。请确认存储权限后重试。'
                : 'Original files were not changed and completed index entries remain usable. Check storage access and try again.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(isChinese ? '确定' : 'OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _backfillRunning = false;
          _backfillCancelRequested = false;
        });
      }
    }
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
                if (defaultTargetPlatform == TargetPlatform.android)
                  ListTile(
                    leading: const Icon(Icons.manage_search_outlined),
                    title: Text(
                      Localizations.localeOf(context).languageCode == 'zh'
                          ? '重建旧下载识图索引'
                          : 'Rebuild old download image index',
                    ),
                    subtitle: Text(
                      _backfillRunning
                          ? (_backfillTotal == 0
                                ? (Localizations.localeOf(
                                            context,
                                          ).languageCode ==
                                          'zh'
                                      ? '正在扫描保存目录…'
                                      : 'Scanning the save folder…')
                                : (Localizations.localeOf(
                                            context,
                                          ).languageCode ==
                                          'zh'
                                      ? '已处理 $_backfillProcessed / $_backfillTotal，已索引 $_backfillIndexed'
                                      : 'Processed $_backfillProcessed / $_backfillTotal, indexed $_backfillIndexed'))
                          : (Localizations.localeOf(context).languageCode ==
                                    'zh'
                                ? '扫描当前保存目录；仅本地计算，不上传图片'
                                : 'Scan the current save folder locally; no upload'),
                    ),
                    trailing: _backfillRunning
                        ? TextButton(
                            onPressed: _backfillCancelRequested
                                ? null
                                : () {
                                    setState(() {
                                      _backfillCancelRequested = true;
                                    });
                                  },
                            child: Text(
                              _backfillCancelRequested
                                  ? (Localizations.localeOf(
                                              context,
                                            ).languageCode ==
                                            'zh'
                                        ? '正在取消'
                                        : 'Cancelling')
                                  : (Localizations.localeOf(
                                              context,
                                            ).languageCode ==
                                            'zh'
                                        ? '取消'
                                        : 'Cancel'),
                            ),
                          )
                        : null,
                    onTap: _backfillRunning
                        ? null
                        : _startDownloadIdentityBackfill,
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
