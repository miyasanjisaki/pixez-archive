import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/network/external_search_transport.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:rhttp/rhttp.dart' as r;

void main() {
  test('all external modes use verified platform TLS without Pixiv DNS', () {
    for (final mode in NetworkMode.values) {
      final settings = PixezNetworkSettings.forExternalService(mode);
      final tls = settings.tlsSettings;

      expect(tls, isNotNull, reason: '$mode must configure TLS explicitly');
      expect(tls!.rootCertSource, r.RootCertSource.platform, reason: '$mode');
      expect(tls.verifyCertificates, isTrue, reason: '$mode');
      expect(tls.sni, isTrue, reason: '$mode');
      expect(tls.trustedRootCertificates, isEmpty, reason: '$mode');
      expect(settings.dnsSettings, isNull, reason: '$mode');
      expect(settings.requireEch, isFalse, reason: '$mode');
    }
  });

  test('ECH is opportunistic only in external ECH mode', () {
    expect(
      PixezNetworkSettings.forExternalService(NetworkMode.standard).enableEch,
      isFalse,
    );
    expect(
      PixezNetworkSettings.forExternalService(NetworkMode.compat).enableEch,
      isFalse,
    );
    final ech = PixezNetworkSettings.forExternalService(NetworkMode.ech);
    expect(ech.enableEch, isTrue);
    expect(ech.requireEch, isFalse);
  });

  test('external platform roots do not change Pixiv TLS policy', () {
    final pixivCompat = PixezNetworkSettings.compatible();
    final pixivEch = PixezNetworkSettings.forHost(
      PixezNetworkSettings.appApiHost,
      NetworkMode.ech,
    );

    expect(pixivCompat.tlsSettings?.rootCertSource, r.RootCertSource.webpki);
    expect(pixivEch?.tlsSettings?.rootCertSource, r.RootCertSource.webpki);
  });

  test('external native transport preserves TLS and bounded timeouts', () {
    for (final mode in NetworkMode.values) {
      final settings = buildExternalSearchClientSettings(mode);
      final tls = settings.tlsSettings;

      expect(settings.timeoutSettings?.timeout, const Duration(seconds: 45));
      expect(
        settings.timeoutSettings?.connectTimeout,
        const Duration(seconds: 20),
      );
      expect(tls?.rootCertSource, r.RootCertSource.platform, reason: '$mode');
      expect(tls?.verifyCertificates, isTrue, reason: '$mode');
      expect(tls?.sni, isTrue, reason: '$mode');
      expect(settings.dnsSettings, isNull, reason: '$mode');
      expect(settings.enableEch, mode == NetworkMode.ech, reason: '$mode');
      expect(settings.requireEch, isFalse, reason: '$mode');
    }
  });
}
