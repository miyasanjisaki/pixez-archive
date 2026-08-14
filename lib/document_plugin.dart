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

import 'package:flutter/services.dart';
import 'package:pixez/main.dart';

class SavedDocumentImage {
  final String token;
  final String displayName;
  final String? relativePath;
  final int? byteLength;

  const SavedDocumentImage({
    required this.token,
    required this.displayName,
    this.relativePath,
    this.byteLength,
  });

  factory SavedDocumentImage.fromMap(Map<Object?, Object?> map) {
    return SavedDocumentImage(
      token: map['token'] as String,
      displayName: map['display_name'] as String,
      relativePath: map['relative_path'] as String?,
      byteLength: (map['byte_length'] as num?)?.toInt(),
    );
  }
}

class DocumentPlugin {
  static const platform = const MethodChannel('com.perol.dev/save');

  static Future<bool?> save(
    Uint8List uint8list,
    String fileName, {
    bool clearOld = false,
    int? saveMode,
  }) async {
    return platform.invokeMethod<bool>('save', {
      "data": uint8list,
      "name": fileName,
      "save_mode": saveMode ?? userSetting.saveMode,
      "clear_old": clearOld,
    });
  }

  static Future<bool?> saveFromPath(
    String sourcePath,
    String fileName, {
    bool clearOld = false,
    int? saveMode,
  }) async {
    return platform.invokeMethod<bool>('saveFromPath', {
      "source_path": sourcePath,
      "name": fileName,
      "save_mode": saveMode ?? userSetting.saveMode,
      "clear_old": clearOld,
    });
  }

  static Future<bool?> openSave(Uint8List uint8list, String fileName) {
    return platform.invokeMethod<bool>('openSave', {
      "data": uint8list,
      "name": fileName,
    });
  }

  static Future<bool?> permissionStatus() async {
    return platform.invokeMethod<bool>('permissionStatus');
  }

  static Future<bool?> requestPermission() async {
    return platform.invokeMethod<bool>('requestPermission');
  }

  static Future<bool?> exist(String fileName, {int? saveMode}) async {
    return platform.invokeMethod<bool>("exist", {
      "name": fileName,
      "save_mode": saveMode ?? userSetting.saveMode,
    });
  }

  static Future<String?> getPath({int? saveMode}) =>
      platform.invokeMethod<String>("get_path", {
        "save_mode": saveMode ?? userSetting.saveMode,
      });

  static Future<dynamic> choiceFolder({int? saveMode}) => platform.invokeMethod(
    "choice_folder",
    {"save_mode": saveMode ?? userSetting.saveMode},
  );

  /// Lists image metadata under the currently authorized PixEz save root.
  /// Image bytes are deliberately loaded one at a time by [readSavedImage].
  static Future<List<SavedDocumentImage>> listSavedImages({
    int maximumCount = 4096,
    int maximumDepth = 8,
    int? saveMode,
  }) async {
    final result = await platform.invokeListMethod<Object?>('listSavedImages', {
      'save_mode': saveMode ?? userSetting.saveMode,
      'max_count': maximumCount,
      'max_depth': maximumDepth,
    });
    if (result == null) return const <SavedDocumentImage>[];
    return result
        .whereType<Map<Object?, Object?>>()
        .map(SavedDocumentImage.fromMap)
        .toList(growable: false);
  }

  /// Reads one image previously returned by [listSavedImages]. Native code
  /// validates that the opaque token is still inside the authorized save root.
  static Future<Uint8List?> readSavedImage(
    String token, {
    int maximumBytes = 64 * 1024 * 1024,
    int? saveMode,
  }) => platform.invokeMethod<Uint8List>('readSavedImage', {
    'save_mode': saveMode ?? userSetting.saveMode,
    'token': token,
    'max_bytes': maximumBytes,
  });
}
