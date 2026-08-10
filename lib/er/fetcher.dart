/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful, but WITHOUT ANY
 *  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 *  FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with
 *  this program. If not, see <http://www.gnu.org/licenses/>.
 */

import 'dart:io';

import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_cache_manager_dio/flutter_cache_manager_dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/er/hoster.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/er/pixiv_image_source.dart';
import 'package:pixez/er/toaster.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/illust.dart';
import 'package:pixez/models/task_persist.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:pixez/store/save_store.dart';
import 'package:pixez/utils/file_name_sanitizer.dart';
import 'package:quiver/collection.dart';
import 'package:rhttp/rhttp.dart' as r;

enum IsoTaskState { INIT, APPEND, PROGRESS, ERROR, COMPLETE, RELOAD }

class IsoContactBean {
  final IsoTaskState state;
  final dynamic data;

  IsoContactBean({required this.state, required this.data});
}

class IsoProgressBean {
  final int min, total;
  final String url;

  IsoProgressBean({required this.min, required this.total, required this.url});
}

class TaskBean {
  String? url;
  Illusts? illusts;
  String? fileName;
  String? savePath;
  String? source;
  String? host;
  NetworkMode? networkMode;

  TaskBean({
    required this.url,
    required this.illusts,
    required this.fileName,
    required this.savePath,
    this.networkMode,
    this.host,
    this.source,
  });
}

class NetworkReloadMessage {
  final NetworkMode networkMode;
  final String? source;

  NetworkReloadMessage({required this.networkMode, required this.source});
}

class Fetcher {
  BuildContext? context;
  List<TaskBean> queue = [];
  ReceivePort receivePort = ReceivePort();
  SendPort? sendPortToChild;
  Isolate? isolate;
  TaskPersistProvider taskPersistProvider = TaskPersistProvider();
  LruMap<String, JobEntity> jobMaps = LruMap();

  Fetcher() {}

  start(String pictureSource) async {
    if (receivePort.isBroadcast) return;
    await taskPersistProvider.open();
    final resumableTasks = (await taskPersistProvider.getAllAccount())
        .where((task) => task.status == 0 || task.status == 1)
        .toList(growable: false);
    LPrinter.d("Fetcher start");
    receivePort.listen((message) async {
      try {
        IsoContactBean isoContactBean = message;
        switch (isoContactBean.state) {
          case IsoTaskState.INIT:
            sendPortToChild = isoContactBean.data;
            for (final task in resumableTasks) {
              if (task.status != 0) {
                await taskPersistProvider.update(task..status = 0);
              }
              await save(task.url, task.toIllusts(), task.fileName);
            }
            await nextJob();
            break;
          case IsoTaskState.PROGRESS:
            IsoProgressBean isoProgressBean = isoContactBean.data;
            var job = fetcher.jobMaps[isoProgressBean.url];
            if (job != null) {
              job
                ..min = isoProgressBean.min
                ..status = 1
                ..max = isoProgressBean.total;
            } else {
              fetcher.jobMaps[isoProgressBean.url] = JobEntity()
                ..status = 1
                ..min = isoProgressBean.min
                ..max = isoProgressBean.total;
            }
            break;
          case IsoTaskState.COMPLETE:
            TaskBean taskBean = isoContactBean.data;
            urlPool.remove(taskBean.url);
            if (queue.isNotEmpty) {
              queue.removeWhere((element) => element.url == taskBean.url);
              LPrinter.d("c ${queue.length}");
            }
            fetcher.jobMaps.removeWhere((key, value) => key == taskBean.url);
            await nextJob();
            await _complete(
              taskBean.url!,
              taskBean.savePath!,
              taskBean.fileName!,
              taskBean.illusts!,
            );
            break;
          case IsoTaskState.ERROR:
            TaskBean taskBean = isoContactBean.data;
            urlPool.remove(taskBean.url);
            if (queue.isNotEmpty) {
              queue.removeWhere((element) => element.url == taskBean.url);
              LPrinter.d("c ${queue.length}");
            }
            fetcher.jobMaps.removeWhere((key, value) => key == taskBean.url);
            await nextJob();
            await _errorD(taskBean.url!);
            break;
          default:
            break;
        }
      } catch (error, stackTrace) {
        LPrinter.d('Download queue event failed: $error');
        LPrinter.d(stackTrace);
      }
    });
    isolate = await Isolate.spawn(
      entryPoint,
      SendMessage(
        receivePort.sendPort,
        pictureSource,
        userSetting.networkMode,
        RootIsolateToken.instance!,
      ),
      debugName: 'childIsolate',
    );
  }

  save(String url, Illusts illusts, String fileName) async {
    LPrinter.d(sendPortToChild.toString() + url);
    final safeFileName = sanitizeRelativeFilePath(
      fileName,
      fallback: '${illusts.id}.jpg',
    );
    var taskBean = TaskBean(
      url: url,
      illusts: illusts,
      fileName: safeFileName,
      networkMode: userSetting.networkMode,
      source: userSetting.pictureSource,
      host: splashStore.host,
      savePath: (await getTemporaryDirectory()).path,
    );
    queue.add(taskBean);
    await nextJob();
  }

  List<String> urlPool = [];

  Future<void> nextJob() async {
    final targetPort = sendPortToChild;
    if (targetPort == null) return;

    while (queue.isNotEmpty &&
        urlPool.length < userSetting.maxRunningTask) {
      TaskBean? first = null;
      for (var i in queue) {
        if (!urlPool.contains(i.url)) {
          first = i;
          break;
        }
      }
      if (first == null) return;
      first.networkMode = userSetting.networkMode;
      first.source = userSetting.pictureSource;
      first.host = splashStore.host;
      IsoContactBean isoContactBean = IsoContactBean(
        state: IsoTaskState.APPEND,
        data: first,
      );
      targetPort.send(isoContactBean);
      if (first.url != null) urlPool.add(first.url!);
      try {
        final persisted = await taskPersistProvider.getAccount(first.url!);
        if (persisted != null && persisted.status != 1) {
          await taskPersistProvider.update(persisted..status = 1);
        }
      } catch (error, stackTrace) {
        LPrinter.d('Unable to persist download start: $error');
        LPrinter.d(stackTrace);
      }
    }
  }

  void stop() {
    isolate?.kill(priority: Isolate.immediate);
  }

  void reloadNetwork() {
    sendPortToChild?.send(
      IsoContactBean(
        state: IsoTaskState.RELOAD,
        data: NetworkReloadMessage(
          networkMode: userSetting.networkMode,
          source: userSetting.pictureSource,
        ),
      ),
    );
  }

  Future<void> _complete(
    String url,
    String savePath,
    String fileName,
    Illusts illusts,
  ) async {
    try {
      var taskPersist = await taskPersistProvider.getAccount(url);
      if (taskPersist == null) return;
      File file = File(savePath + Platform.pathSeparator + fileName);
      if (!await file.exists()) {
        await _errorD(url);
        return;
      }

      final uint8list = await file.readAsBytes();
      final saved = await saveStore.saveToGallery(uint8list, illusts, fileName);
      if (!saved) {
        await _errorD(url);
        return;
      }

      await taskPersistProvider.update(taskPersist..status = 2);
      try {
        await file.delete();
      } on FileSystemException catch (error) {
        LPrinter.d(error);
      }
      if (context != null) {
        Toaster.downloadOk("${illusts.title} ${I18n.of(context!).saved}");
      }
      var job = jobMaps[url];
      if (job != null) {
        job.status = 2;
      } else {
        jobMaps[url] = JobEntity()
          ..status = 2
          ..min = 1
          ..max = 1;
      }
    } catch (error, stackTrace) {
      LPrinter.d('Downloaded file could not be persisted: $error');
      LPrinter.d(stackTrace);
      await _errorD(url);
    }
  }

  Future<void> _errorD(String url) async {
    var taskPersist = await taskPersistProvider.getAccount(url);
    if (taskPersist == null) return;
    await taskPersistProvider.update(taskPersist..status = 3);
    var job = jobMaps[url];
    if (job != null) {
      job.status = 3;
    } else {
      jobMaps[url] = JobEntity()
        ..status = 3
        ..min = 1
        ..max = 1;
    }
  }
}

class SendMessage {
  final SendPort sendPort;
  final String pictureSource;
  final NetworkMode networkMode;
  final RootIsolateToken rootIsolateToken;

  SendMessage(
    this.sendPort,
    this.pictureSource,
    this.networkMode,
    this.rootIsolateToken,
  );
}

entryPoint(SendMessage message) async {
  String pictureSource = message.pictureSource;
  var currentPictureSource = pictureSource;
  var currentNetworkMode = message.networkMode;
  RootIsolateToken rootIsolateToken = message.rootIsolateToken;
  SendPort sendPort = message.sendPort;
  LPrinter.d("entryPoint ====== $pictureSource");
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
  await r.Rhttp.init();
  await Hoster.initMap();
  Hoster.dnsQueryFetcher();
  final dio = Dio();
  final client = await r.RhttpCompatibleClient.createSync(
    settings: PixezNetworkSettings.forImages(
      currentPictureSource,
      currentNetworkMode,
    ),
  );
  dio.interceptors.add(
    PixivImageSourceInterceptor(
      networkMode: () => currentNetworkMode,
      pictureSource: () => currentPictureSource,
    ),
  );
  dio.httpClientAdapter = ConversionLayerAdapter(client);
  DioCacheManager.initialize(dio);
  ReceivePort receivePort = ReceivePort();
  sendPort.send(
    IsoContactBean(state: IsoTaskState.INIT, data: receivePort.sendPort),
  );

  receivePort.listen((message) async {
    try {
      IsoContactBean isoContactBean = message;
      if (isoContactBean.state == IsoTaskState.RELOAD) {
        final reload = isoContactBean.data as NetworkReloadMessage;
        currentNetworkMode = reload.networkMode;
        currentPictureSource = reload.source ?? PixezNetworkSettings.imageHost;
        final newClient = await r.RhttpCompatibleClient.createSync(
          settings: PixezNetworkSettings.forImages(
            currentPictureSource,
            currentNetworkMode,
          ),
        );
        dio.httpClientAdapter = ConversionLayerAdapter(newClient);
        return;
      }
      TaskBean taskBean = isoContactBean.data;
      switch (isoContactBean.state) {
        case IsoTaskState.ERROR:
          break;
        case IsoTaskState.APPEND:
          try {
            currentPictureSource = taskBean.source ?? pictureSource;
            currentNetworkMode = taskBean.networkMode ?? message.networkMode;
            print("========taskBean.savePath: ${taskBean.savePath}");
            final safeFileName = sanitizeRelativeFilePath(
              taskBean.fileName!,
              fallback: '${taskBean.illusts?.id ?? 'download'}.jpg',
            );
            taskBean.fileName = safeFileName;
            final temporaryDirectory = Directory(taskBean.savePath!).absolute;
            final targetFile = File(
              '${temporaryDirectory.path}${Platform.pathSeparator}$safeFileName',
            ).absolute;
            final rootPrefix =
                '${temporaryDirectory.path}${Platform.pathSeparator}';
            final comparableRoot =
                Platform.isWindows ? rootPrefix.toLowerCase() : rootPrefix;
            final comparableTarget = Platform.isWindows
                ? targetFile.path.toLowerCase()
                : targetFile.path;
            if (!comparableTarget.startsWith(comparableRoot)) {
              throw FileSystemException(
                'Download path escaped the temporary directory',
                targetFile.path,
              );
            }
            await for (final response in pixivCacheManager!.getFileStream(
              taskBean.url!,
              headers: {
                "referer": "https://app-api.pixiv.net/",
                "User-Agent": "PixivIOSApp/5.8.0",
              },
              withProgress: true,
            )) {
              if (response is DownloadProgress) {
                sendPort.send(
                  IsoContactBean(
                    state: IsoTaskState.PROGRESS,
                    data: IsoProgressBean(
                      min: response.downloaded,
                      total: response.totalSize ?? 1,
                      url: taskBean.url!,
                    ),
                  ),
                );
              } else if (response is FileInfo) {
                File file = targetFile;
                if (!file.parent.existsSync()) {
                  file.parent.createSync(recursive: true);
                }
                await response.file.copy(file.path);
                sendPort.send(
                  IsoContactBean(state: IsoTaskState.COMPLETE, data: taskBean),
                );
              }
            }
          } catch (e) {
            LPrinter.d("fetcher=======");
            LPrinter.d(e);
            sendPort.send(
              IsoContactBean(state: IsoTaskState.ERROR, data: taskBean),
            );
          }
          break;
        default:
          break;
      }
    } catch (e) {
      LPrinter.d(e);
    }
  });
}
