import 'dart:io';

import 'package:pixez/er/hoster.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:rhttp/rhttp.dart' as r;

/// A fully verified trust implementation used by an external HTTPS provider.
///
/// These channels differ only in where their trusted roots and certificate
/// path implementation come from. Certificate and hostname verification are
/// never disabled.
enum ExternalTlsTrustChannel { webpki, platform, androidSecurityContext }

/// Ordered trust channels allowed for one exact external-service host.
class ExternalTlsHostPlan {
  const ExternalTlsHostPlan({
    required this.primary,
    this.invalidCertificateFallbacks = const <ExternalTlsTrustChannel>[],
  });

  final ExternalTlsTrustChannel primary;
  final List<ExternalTlsTrustChannel> invalidCertificateFallbacks;

  Iterable<ExternalTlsTrustChannel> get channels sync* {
    yield primary;
    yield* invalidCertificateFallbacks;
  }
}

class PixezNetworkSettings {
  static const appApiHost = 'app-api.pixiv.net';
  static const oauthHost = 'oauth.secure.pixiv.net';
  static const accountHost = 'accounts.pixiv.net';
  static const imageHost = 'i.pximg.net';
  static const imageStaticHost = 's.pximg.net';

  static r.ClientSettings? forHost(String host, NetworkMode mode) {
    if (mode == NetworkMode.standard) return null;
    if (mode == NetworkMode.ech) {
      return r.ClientSettings(
        enableEch: true,
        requireEch: true,
        tlsSettings: r.TlsSettings(
          verifyCertificates: true,
          rootCertSource: r.RootCertSource.webpki,
          sni: true,
        ),
        dnsSettings: r.DnsSettings.static(
          overrides: {
            appApiHost: ['104.18.10.118', '104.18.11.118'],
            oauthHost: ['104.18.10.118', '104.18.11.118'],
            accountHost: ['104.18.10.118', '104.18.11.118'],
          },
        ),
      );
    }
    return compatible();
  }

  static r.ClientSettings? forImages(String? host, NetworkMode mode) {
    if (mode == NetworkMode.standard) return null;
    if (host != imageHost) return null;
    return compatible();
  }

  /// Network settings for third-party HTTPS services such as reverse-image
  /// search providers.
  ///
  /// External hosts must never inherit Pixiv's static DNS or ECH bootstrap.
  ///
  /// The vendored ECH lookup is intentionally Pixiv-specific, so enabling it
  /// for unrelated providers can present the wrong ECH configuration and can
  /// also force TLS 1.3 against a TLS 1.2-only service. External providers use
  /// their normal, fully verified TLS negotiation instead.
  static r.ClientSettings forExternalService(
    NetworkMode mode, {
    ExternalTlsTrustChannel trustChannel = ExternalTlsTrustChannel.webpki,
  }) {
    if (trustChannel == ExternalTlsTrustChannel.androidSecurityContext) {
      throw ArgumentError.value(
        trustChannel,
        'trustChannel',
        'Dart IO trust is not an rhttp client setting',
      );
    }
    return r.ClientSettings(
      throwOnStatusCode: false,
      enableEch: false,
      requireEch: false,
      redirectSettings: const r.RedirectSettings.none(),
      tlsSettings: _verifiedExternalTlsSettings(trustChannel),
    );
  }

  /// Returns the only trust-channel sequence allowed for [host].
  ///
  /// Android gets narrow, typed-certificate fallbacks for the two known
  /// reverse-image providers. Every other host and every non-Android platform
  /// remains WebPKI-only. The Dart IO channel is deliberately restricted to
  /// these two hosts because it exists to bypass the Android verifier
  /// regression in the vendored rustls platform-verifier path, not as a
  /// general trust fallback.
  static ExternalTlsHostPlan externalTlsHostPlan(
    String host, {
    bool? isAndroid,
  }) {
    const webpkiOnly = ExternalTlsHostPlan(
      primary: ExternalTlsTrustChannel.webpki,
    );
    if (!(isAndroid ?? Platform.isAndroid)) return webpkiOnly;

    return switch (host.toLowerCase()) {
      'saucenao.com' => const ExternalTlsHostPlan(
        primary: ExternalTlsTrustChannel.webpki,
        invalidCertificateFallbacks: <ExternalTlsTrustChannel>[
          ExternalTlsTrustChannel.androidSecurityContext,
        ],
      ),
      'safe.iqdb.org' => const ExternalTlsHostPlan(
        primary: ExternalTlsTrustChannel.webpki,
        invalidCertificateFallbacks: <ExternalTlsTrustChannel>[
          ExternalTlsTrustChannel.androidSecurityContext,
        ],
      ),
      _ => webpkiOnly,
    };
  }

  static r.ClientSettings compatible() {
    return r.ClientSettings(
      // DNS overrides must not weaken HTTPS. The request still targets the
      // original hostname, so certificate verification and SNI remain valid
      // even when the resolver supplies a custom IP address.
      tlsSettings: _verifiedTlsSettings(),
      dnsSettings: r.DnsSettings.dynamic(
        resolver: (host) async {
          final ip = _compatibleIp(host);
          if (ip != null) return [ip];
          return await InternetAddress.lookup(
            host,
          ).then((value) => value.map((e) => e.address).toList());
        },
      ),
    );
  }

  static r.TlsSettings _verifiedTlsSettings() {
    return r.TlsSettings(
      verifyCertificates: true,
      rootCertSource: r.RootCertSource.webpki,
      sni: true,
    );
  }

  static r.TlsSettings _verifiedExternalTlsSettings(
    ExternalTlsTrustChannel trustChannel,
  ) {
    return r.TlsSettings(
      verifyCertificates: true,
      rootCertSource: switch (trustChannel) {
        ExternalTlsTrustChannel.webpki => r.RootCertSource.webpki,
        ExternalTlsTrustChannel.platform => r.RootCertSource.platform,
        ExternalTlsTrustChannel.androidSecurityContext => throw StateError(
          'Dart IO trust cannot be converted to rhttp TLS',
        ),
      },
      sni: true,
    );
  }

  static String? _compatibleIp(String host) {
    if (host == appApiHost) return Hoster.api();
    if (host == oauthHost) return Hoster.oauth();
    if (host == imageHost) return Hoster.iPximgNet();
    if (host == imageStaticHost) return Hoster.sPximgNet();
    return null;
  }
}
