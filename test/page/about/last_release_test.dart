import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/page/about/last_release.dart';

void main() {
  test('prefers a universal Android APK over architecture-specific assets', () {
    final release = LastRelease.fromJson({
      'html_url': 'https://example.test/release',
      'assets': [
        {
          'name': 'pixez-windows-x86_64.zip',
          'browser_download_url': 'https://example.test/windows.zip',
        },
        {
          'name': 'app-universal-release.apk',
          'browser_download_url': 'https://example.test/universal.apk',
        },
        {
          'name': 'PixEz-Archive-arm64-v8a.apk',
          'browser_download_url': 'https://example.test/arm64.apk',
        },
      ],
    });

    expect(
      release.preferredAndroidDownloadUrl,
      'https://example.test/universal.apk',
    );
    expect(
      release.preferredWindowsDownloadUrl,
      'https://example.test/windows.zip',
    );
  });

  test('falls back to the release page when no compatible APK exists', () {
    final release = LastRelease.fromJson({
      'html_url': 'https://example.test/release',
      'assets': [
        {
          'name': 'app-x86_64-release.apk',
          'browser_download_url': 'https://example.test/x86.apk',
        },
      ],
    });

    expect(release.preferredAndroidDownloadUrl, 'https://example.test/release');
  });
}
