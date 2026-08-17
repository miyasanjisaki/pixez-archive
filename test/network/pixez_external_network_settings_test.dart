import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/network/external_search_transport.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:rhttp/rhttp.dart' as r;

void main() {
  test('Android known-host plans use one strict system-trust fallback', () {
    for (final host in const <String>['saucenao.com', 'safe.iqdb.org']) {
      final plan = PixezNetworkSettings.externalTlsHostPlan(
        host,
        isAndroid: true,
      );
      expect(plan.channels, <ExternalTlsTrustChannel>[
        ExternalTlsTrustChannel.webpki,
        ExternalTlsTrustChannel.androidSecurityContext,
      ], reason: host);
    }
  });

  test('unknown hosts and non-Android hosts remain WebPKI-only', () {
    expect(
      PixezNetworkSettings.externalTlsHostPlan(
        'saucenao.com.evil.test',
        isAndroid: true,
      ).channels,
      <ExternalTlsTrustChannel>[ExternalTlsTrustChannel.webpki],
    );
    expect(
      PixezNetworkSettings.externalTlsHostPlan(
        'safe.iqdb.org',
        isAndroid: false,
      ).channels,
      <ExternalTlsTrustChannel>[ExternalTlsTrustChannel.webpki],
    );
  });

  test('rhttp trust channels stay verified and isolated from Pixiv DNS', () {
    for (final mode in NetworkMode.values) {
      for (final entry in const <ExternalTlsTrustChannel, r.RootCertSource>{
        ExternalTlsTrustChannel.webpki: r.RootCertSource.webpki,
        ExternalTlsTrustChannel.platform: r.RootCertSource.platform,
      }.entries) {
        final settings = PixezNetworkSettings.forExternalService(
          mode,
          trustChannel: entry.key,
        );
        final tls = settings.tlsSettings;

        expect(tls, isNotNull, reason: '$mode ${entry.key}');
        expect(tls!.rootCertSource, entry.value);
        expect(tls.verifyCertificates, isTrue);
        expect(tls.sni, isTrue);
        expect(tls.trustedRootCertificates, isEmpty);
        expect(settings.dnsSettings, isNull);
        expect(settings.throwOnStatusCode, isFalse);
        expect(
          settings.redirectSettings,
          same(const r.RedirectSettings.none()),
        );
        expect(settings.requireEch, isFalse);
      }
    }
  });

  test('Dart IO trust cannot be converted into an rhttp setting', () {
    expect(
      () => PixezNetworkSettings.forExternalService(
        NetworkMode.standard,
        trustChannel: ExternalTlsTrustChannel.androidSecurityContext,
      ),
      throwsArgumentError,
    );
  });

  test('external services never inherit Pixiv ECH bootstrap', () {
    for (final mode in NetworkMode.values) {
      final settings = PixezNetworkSettings.forExternalService(mode);
      expect(settings.enableEch, isFalse, reason: '$mode');
      expect(settings.requireEch, isFalse, reason: '$mode');
    }
  });

  test('external trust channels do not change Pixiv TLS policy', () {
    final pixivCompat = PixezNetworkSettings.compatible();
    final pixivEch = PixezNetworkSettings.forHost(
      PixezNetworkSettings.appApiHost,
      NetworkMode.ech,
    );

    expect(pixivCompat.tlsSettings?.rootCertSource, r.RootCertSource.webpki);
    expect(pixivEch?.tlsSettings?.rootCertSource, r.RootCertSource.webpki);
    expect(pixivEch?.enableEch, isTrue);
    expect(pixivEch?.requireEch, isTrue);
  });

  test('copyWith adds timeouts without losing strict transport settings', () {
    for (final mode in NetworkMode.values) {
      final settings = buildExternalSearchClientSettings(
        mode,
        trustChannel: ExternalTlsTrustChannel.webpki,
      );
      final tls = settings.tlsSettings;

      expect(settings.timeoutSettings?.timeout, const Duration(seconds: 45));
      expect(
        settings.timeoutSettings?.connectTimeout,
        const Duration(seconds: 20),
      );
      expect(tls?.rootCertSource, r.RootCertSource.webpki, reason: '$mode');
      expect(tls?.verifyCertificates, isTrue, reason: '$mode');
      expect(tls?.sni, isTrue, reason: '$mode');
      expect(tls?.trustedRootCertificates, isEmpty, reason: '$mode');
      expect(settings.dnsSettings, isNull, reason: '$mode');
      expect(settings.enableEch, isFalse, reason: '$mode');
      expect(settings.requireEch, isFalse, reason: '$mode');
      expect(settings.throwOnStatusCode, isFalse, reason: '$mode');
      expect(settings.redirectSettings, same(const r.RedirectSettings.none()));
    }
  });

  test('Dio policy disables redirects and uses bounded timeouts', () {
    final options = buildExternalSearchBaseOptions('https://saucenao.com');

    expect(options.followRedirects, isFalse);
    expect(options.connectTimeout, const Duration(seconds: 20));
    expect(options.sendTimeout, const Duration(seconds: 45));
    expect(options.receiveTimeout, const Duration(seconds: 45));
  });
}
