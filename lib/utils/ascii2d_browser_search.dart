import 'dart:typed_data';

const String ascii2dOrigin = 'https://ascii2d.net';
const int ascii2dMaximumUploadBytes = 10 * 1024 * 1024;

enum Ascii2dImageFormat { jpeg, png, webp }

enum Ascii2dResultMode { color, feature }

class Ascii2dUploadValidation {
  final Ascii2dImageFormat? format;
  final String? error;

  const Ascii2dUploadValidation._({this.format, this.error});

  bool get isValid => format != null && error == null;

  String get fileExtension => switch (format) {
    Ascii2dImageFormat.jpeg => 'jpg',
    Ascii2dImageFormat.png => 'png',
    Ascii2dImageFormat.webp => 'webp',
    null => 'bin',
  };

  static Ascii2dUploadValidation valid(Ascii2dImageFormat format) =>
      Ascii2dUploadValidation._(format: format);

  static Ascii2dUploadValidation invalid(String error) =>
      Ascii2dUploadValidation._(error: error);
}

Ascii2dUploadValidation validateAscii2dUpload(Uint8List bytes) {
  if (bytes.isEmpty) {
    return Ascii2dUploadValidation.invalid('图片内容为空');
  }
  if (bytes.length > ascii2dMaximumUploadBytes) {
    return Ascii2dUploadValidation.invalid('Ascii2D 网页最大支持 10 MB 图片');
  }
  if (_startsWith(bytes, const [0xff, 0xd8, 0xff])) {
    return Ascii2dUploadValidation.valid(Ascii2dImageFormat.jpeg);
  }
  if (_startsWith(bytes, const [
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
  ])) {
    return Ascii2dUploadValidation.valid(Ascii2dImageFormat.png);
  }
  if (bytes.length >= 12 &&
      _ascii(bytes, 0, 4) == 'RIFF' &&
      _ascii(bytes, 8, 12) == 'WEBP') {
    return Ascii2dUploadValidation.valid(Ascii2dImageFormat.webp);
  }
  return Ascii2dUploadValidation.invalid('仅支持 JPEG、PNG 或 WebP 图片');
}

bool isTrustedAscii2dUri(Uri? uri) {
  if (uri == null || uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  return host == 'ascii2d.net' || host == 'www.ascii2d.net';
}

bool isAscii2dUploadPageUri(Uri? uri) {
  if (!isTrustedAscii2dUri(uri)) return false;
  return uri!.path.isEmpty || uri.path == '/' || uri.path == '/search/file';
}

int? pixivArtworkIdFromUri(Uri? uri) {
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host != 'pixiv.net' && !host.endsWith('.pixiv.net')) return null;
  final index = uri.pathSegments.indexOf('artworks');
  int? id;
  if (index >= 0 && index + 1 < uri.pathSegments.length) {
    id = int.tryParse(uri.pathSegments[index + 1]);
  }
  if (id == null) {
    final shortIndex = uri.pathSegments.indexOf('i');
    if (shortIndex >= 0 && shortIndex + 1 < uri.pathSegments.length) {
      id = int.tryParse(uri.pathSegments[shortIndex + 1]);
    }
  }
  id ??= int.tryParse(uri.queryParameters['illust_id'] ?? '');
  return id != null && id > 0 ? id : null;
}

Uri? ascii2dResultModeUri(Uri? current, Ascii2dResultMode mode) {
  if (!isTrustedAscii2dUri(current)) return null;
  final segments = current!.pathSegments.toList(growable: false);
  if (segments.length < 3 || segments.first != 'search') return null;
  final currentMode = segments[1];
  if (currentMode != 'color' && currentMode != 'bovw') return null;
  final nextMode = mode == Ascii2dResultMode.color ? 'color' : 'bovw';
  return current.replace(
    pathSegments: [segments.first, nextMode, ...segments.skip(2)],
  );
}

class Ascii2dUploadGate {
  final Duration lifetime;
  DateTime? _armedAt;

  Ascii2dUploadGate({this.lifetime = const Duration(minutes: 1)});

  bool get isArmed => _armedAt != null;

  void arm(DateTime now) {
    _armedAt = now.toUtc();
  }

  void cancel() {
    _armedAt = null;
  }

  bool consume({required Uri? pageUri, required DateTime now}) {
    final armedAt = _armedAt;
    _armedAt = null;
    if (armedAt == null || !isTrustedAscii2dUri(pageUri)) return false;
    final age = now.toUtc().difference(armedAt);
    return !age.isNegative && age <= lifetime;
  }
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  return true;
}

String _ascii(Uint8List bytes, int start, int end) =>
    String.fromCharCodes(bytes.sublist(start, end));
