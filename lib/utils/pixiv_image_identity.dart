import 'dart:convert';
import 'dart:typed_data';

const int _maxMetadataScanBytes = 4 * 1024 * 1024;
const int _metadataTailBytes = 256 * 1024;

final List<RegExp> _explicitPixivIdPatterns = [
  RegExp(
    r'pixiv\.net/(?:[a-z]{2}/)?artworks/([1-9][0-9]{0,11})',
    caseSensitive: false,
  ),
  RegExp(
    r'(?:[?&]|&amp;)illust_id(?:=|%3d)([1-9][0-9]{0,11})',
    caseSensitive: false,
  ),
  RegExp(
    r'pixiv[ _-]+(?:illust[ _-]+)?id[ _:=#-]+([1-9][0-9]{4,11})',
    caseSensitive: false,
  ),
];

final RegExp _canonicalPixivFileName = RegExp(
  r'(?:^|[^0-9])([1-9][0-9]{4,11})_p[0-9]+[^/\\]*\.(?:jpe?g|png|webp|gif|avif)(?:$|[?#])',
  caseSensitive: false,
);

/// Extracts Pixiv illustration IDs only from explicit Pixiv URLs, labels, or
/// canonical Pixiv image file names such as `123456789_p0.jpg`, or an explicit
/// `Pixiv ID: 123456789` label.
///
/// It deliberately does not treat every long number as an illustration ID;
/// camera file names and timestamps are common in Android photo libraries.
List<int> extractPixivIllustIdsFromText(String text) {
  if (text.isEmpty) return const [];

  final candidates = <int>[];
  final seen = <int>{};

  void collect(RegExp expression, String value) {
    for (final match in expression.allMatches(value)) {
      final id = int.tryParse(match.group(1) ?? '');
      if (id != null && id > 0 && seen.add(id)) candidates.add(id);
    }
  }

  final variants = <String>[text];
  try {
    final decoded = Uri.decodeFull(text);
    if (decoded != text) variants.add(decoded);
  } on FormatException {
    // A malformed percent escape should not prevent the other hints from
    // being inspected.
  } on ArgumentError {
    // Uri.decodeFull also reports malformed percent escapes and arbitrary
    // binary metadata as ArgumentError on some Dart versions.
  }

  for (final variant in variants) {
    collect(_canonicalPixivFileName, variant);
    for (final pattern in _explicitPixivIdPatterns) {
      collect(pattern, variant);
    }
  }
  return candidates;
}

/// Finds the first Pixiv ID from picker display names, file/content URIs and,
/// when needed, textual JPEG/PNG metadata embedded in [bytes].
int? extractPixivIllustId({
  Iterable<String?> hints = const [],
  Uint8List? bytes,
}) {
  for (final hint in hints) {
    if (hint == null || hint.isEmpty) continue;
    final ids = extractPixivIllustIdsFromText(hint);
    if (ids.isNotEmpty) return ids.first;
  }

  if (bytes == null || bytes.isEmpty) return null;
  for (final window in _metadataWindows(bytes)) {
    // JPEG EXIF comments and PNG tEXt/iTXt chunks retain their ASCII payload
    // in the byte stream. Latin-1 is lossless for that inspection.
    final ids = extractPixivIllustIdsFromText(latin1.decode(window));
    if (ids.isNotEmpty) return ids.first;
  }
  return null;
}

/// Isolate-friendly entry point for inspecting image metadata bytes.
int? extractPixivIllustIdFromBytes(Uint8List bytes) {
  return extractPixivIllustId(bytes: bytes);
}

Iterable<Uint8List> _metadataWindows(Uint8List bytes) sync* {
  if (bytes.length <= _maxMetadataScanBytes) {
    yield bytes;
    return;
  }

  yield Uint8List.sublistView(bytes, 0, _maxMetadataScanBytes);
  yield Uint8List.sublistView(
    bytes,
    bytes.length - _metadataTailBytes,
    bytes.length,
  );
}
