import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/network/external_search_transport.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/network/pixez_network_settings.dart';

void main() {
  test('standard external transport keeps the system defaults', () {
    expect(
      PixezNetworkSettings.forExternalService(NetworkMode.standard),
      isNull,
    );
  });

  test('external ECH is opportunistic and has no Pixiv DNS override', () {
    final settings = PixezNetworkSettings.forExternalService(NetworkMode.ech);

    expect(settings, isNotNull);
    expect(settings!.enableEch, isTrue);
    expect(settings.requireEch, isFalse);
    expect(settings.dnsSettings, isNull);
    expect(settings.tlsSettings?.verifyCertificates, isTrue);
    expect(settings.tlsSettings?.sni, isTrue);
  });

  test('compat external transport retains verified TLS and dynamic DNS', () {
    final settings = PixezNetworkSettings.forExternalService(
      NetworkMode.compat,
    );

    expect(settings, isNotNull);
    expect(settings!.enableEch, isFalse);
    expect(settings.requireEch, isFalse);
    expect(settings.dnsSettings, isNotNull);
    expect(settings.tlsSettings?.verifyCertificates, isTrue);
    expect(settings.tlsSettings?.sni, isTrue);
  });

  test('external native transport has bounded total and connect timeouts', () {
    for (final mode in NetworkMode.values) {
      final settings = buildExternalSearchClientSettings(mode);

      expect(settings.timeoutSettings?.timeout, const Duration(seconds: 45));
      expect(
        settings.timeoutSettings?.connectTimeout,
        const Duration(seconds: 20),
      );
    }
  });
}
