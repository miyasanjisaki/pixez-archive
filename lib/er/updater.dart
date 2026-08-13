import 'package:dio/dio.dart';
import 'package:pixez/constants.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pub_semver/pub_semver.dart';

enum Result { yes, no, timeout }

class Updater {
  static Result result = Result.timeout;
  static String? latestVersion;

  static Future<Result> check() async {
    if (Constants.isGooglePlay) return Result.no;
    final update = await checkUpdate();
    result = update.result;
    latestVersion = update.latestVersion;
    return update.result;
  }
}

Future<({Result result, String? latestVersion})> checkUpdate() async {
  LPrinter.d("check for update ============");
  try {
    final response = await Dio(
      BaseOptions(baseUrl: 'https://api.github.com'),
    ).get('/repos/miyasanjisaki/pixez-archive/releases/latest');
    final tagName = response.data['tag_name']?.toString();
    if (tagName == null || tagName.isEmpty) {
      return (result: Result.timeout, latestVersion: null);
    }
    LPrinter.d("tagName:$tagName ");
    final hasUpdate = isRemoteVersionNewer(tagName, Constants.tagName);
    return (result: hasUpdate ? Result.yes : Result.no, latestVersion: tagName);
  } catch (e) {
    LPrinter.d('Update check failed: $e');
    return (result: Result.timeout, latestVersion: null);
  }
}

bool isRemoteVersionNewer(String remoteTag, String localTag) {
  try {
    final remote = Version.parse(_normalizeVersionTag(remoteTag));
    final local = Version.parse(_normalizeVersionTag(localTag));
    return remote.compareTo(local) > 0;
  } on FormatException {
    return false;
  }
}

String _normalizeVersionTag(String tag) {
  var normalized = tag.trim();
  if (normalized.isEmpty) return normalized;
  if (normalized.startsWith('v') || normalized.startsWith('V')) {
    normalized = normalized.substring(1);
  }
  return normalized.split(RegExp(r'\s+')).first;
}
