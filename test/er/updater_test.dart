import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/er/updater.dart';

void main() {
  group('isRemoteVersionNewer', () {
    test('compares the first differing numeric segment', () {
      expect(isRemoteVersionNewer('0.10.0', '0.9.108'), isTrue);
      expect(isRemoteVersionNewer('0.8.999', '0.9.108'), isFalse);
    });

    test('supports a v prefix and semantic prerelease ordering', () {
      expect(isRemoteVersionNewer('v0.9.109', '0.9.108'), isTrue);
      expect(isRemoteVersionNewer('0.9.108-beta.2', '0.9.108'), isFalse);
      expect(isRemoteVersionNewer('0.9.109-beta.1', '0.9.108'), isTrue);
    });

    test('does not advertise malformed tags as updates', () {
      expect(isRemoteVersionNewer('release-latest', '0.9.108'), isFalse);
    });
  });
}
