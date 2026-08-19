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
class LastRelease {
  String? tagName;
  List<Assets>? assets;
  String? body;
  String? htmlUrl;

  LastRelease({this.tagName, this.assets, this.body, this.htmlUrl});

  factory LastRelease.fromJson(Map<String, dynamic> json) {
    List<Assets>? assets;
    if (json['assets'] != null) {
      assets = [];
      json['assets'].forEach((v) {
        assets!.add(Assets.fromJson(v));
      });
    }
    return LastRelease(
      tagName: json['tag_name']?.toString(),
      assets: assets,
      body: json['body']?.toString(),
      htmlUrl: json['html_url']?.toString(),
    );
  }

  String? get preferredAndroidDownloadUrl {
    final candidates =
        (assets ?? const <Assets>[])
            .where((asset) => asset.isCompatibleAndroidApk)
            .toList(growable: false)
          ..sort(
            (left, right) =>
                right.androidPreference.compareTo(left.androidPreference),
          );
    return candidates.isEmpty
        ? htmlUrl
        : candidates.first.browserDownloadUrl ?? htmlUrl;
  }

  String? get preferredWindowsDownloadUrl {
    final candidates =
        (assets ?? const <Assets>[])
            .where((asset) => asset.windowsPreference > 0)
            .toList(growable: false)
          ..sort(
            (left, right) =>
                right.windowsPreference.compareTo(left.windowsPreference),
          );
    return candidates.isEmpty
        ? htmlUrl
        : candidates.first.browserDownloadUrl ?? htmlUrl;
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['tag_name'] = this.tagName;
    if (this.assets != null) {
      data['assets'] = this.assets!.map((v) => v.toJson()).toList();
    }
    data['body'] = this.body;
    data['html_url'] = this.htmlUrl;
    return data;
  }
}

class Assets {
  String? browserDownloadUrl;
  String? name;
  String? contentType;

  Assets({this.browserDownloadUrl, this.name, this.contentType});

  factory Assets.fromJson(Map<String, dynamic> json) {
    return Assets(
      browserDownloadUrl: json['browser_download_url']?.toString(),
      name: json['name']?.toString(),
      contentType: json['content_type']?.toString(),
    );
  }

  String get _lowerName => (name ?? '').toLowerCase();

  bool get isCompatibleAndroidApk {
    if (browserDownloadUrl?.isNotEmpty != true ||
        !_lowerName.endsWith('.apk')) {
      return false;
    }
    return !_lowerName.contains('x86') &&
        !_lowerName.contains('armeabi-v7a') &&
        !_lowerName.contains('arm-v7a');
  }

  int get androidPreference {
    if (!isCompatibleAndroidApk) return 0;
    if (_lowerName.contains('universal')) return 300;
    if (_lowerName.contains('arm64-v8a') || _lowerName.contains('arm64')) {
      return 200;
    }
    return 100;
  }

  int get windowsPreference {
    if (browserDownloadUrl?.isNotEmpty != true) return 0;
    var score = switch (_lowerName) {
      final value when value.endsWith('.msix') => 300,
      final value when value.endsWith('.exe') => 250,
      final value when value.endsWith('.zip') => 200,
      _ => 0,
    };
    if (score > 0 &&
        (_lowerName.contains('x86_64') || _lowerName.contains('x64'))) {
      score += 20;
    }
    return score;
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['browser_download_url'] = this.browserDownloadUrl;
    data['name'] = this.name;
    data['content_type'] = this.contentType;
    return data;
  }
}
