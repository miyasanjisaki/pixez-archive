const int defaultMaxFileNameLength = 180;

final RegExp _invalidFileNameCharacters = RegExp(r'[\x00-\x1f<>:"/\\|?*]');
final RegExp _trailingDotsAndSpaces = RegExp(r'[. ]+$');
final RegExp _repeatedReplacementCharacters = RegExp(r'_+');
final RegExp _windowsReservedName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
  caseSensitive: false,
);

/// Converts untrusted artwork metadata into one portable file-name component.
///
/// Directory separators, control characters, Windows-reserved device names,
/// trailing dots/spaces, and overlong values are handled here. The returned
/// value never contains a path, so callers must add directories separately.
String sanitizeFileNameComponent(
  String input, {
  String fallback = 'untitled',
  int maxLength = defaultMaxFileNameLength,
}) {
  if (maxLength < 1) {
    throw ArgumentError.value(maxLength, 'maxLength', 'must be positive');
  }

  var value = input
      .replaceAll(_invalidFileNameCharacters, '_')
      .replaceAll(_repeatedReplacementCharacters, '_')
      .trim()
      .replaceAll(_trailingDotsAndSpaces, '');

  if (value.isEmpty || value == '.' || value == '..') {
    value = _sanitizeFallback(fallback);
  }

  if (_windowsReservedName.hasMatch(value)) {
    value = '_$value';
  }

  value = _truncatePreservingExtension(value, maxLength);
  value = value.replaceAll(_trailingDotsAndSpaces, '');

  return value.isEmpty ? 'untitled' : value;
}

/// Sanitizes every component of a relative path while preserving safe
/// subdirectories such as `artist_id/file.jpg`.
String sanitizeRelativeFilePath(
  String input, {
  String fallback = 'untitled',
}) {
  final components = input
      .replaceAll('\\', '/')
      .split('/')
      .where((component) => component.isNotEmpty)
      .map(
        (component) => sanitizeFileNameComponent(
          component,
          fallback: '_',
        ),
      )
      .toList(growable: false);
  if (components.isEmpty) {
    return sanitizeFileNameComponent(fallback);
  }
  return components.join('/');
}

String _sanitizeFallback(String fallback) {
  final value = fallback
      .replaceAll(_invalidFileNameCharacters, '_')
      .replaceAll(_repeatedReplacementCharacters, '_')
      .trim()
      .replaceAll(_trailingDotsAndSpaces, '');
  return value.isEmpty || value == '.' || value == '..' ? 'untitled' : value;
}

String _truncatePreservingExtension(String value, int maxLength) {
  if (value.runes.length <= maxLength) return value;

  final extensionIndex = value.lastIndexOf('.');
  final hasShortExtension =
      extensionIndex > 0 && value.substring(extensionIndex).runes.length <= 16;
  final extension = hasShortExtension ? value.substring(extensionIndex) : '';
  final extensionLength = extension.runes.length;
  final stemLength = maxLength - extensionLength;

  if (stemLength < 1) {
    return String.fromCharCodes(value.runes.take(maxLength));
  }

  final stemSource = hasShortExtension
      ? value.substring(0, extensionIndex)
      : value;
  final stem = String.fromCharCodes(stemSource.runes.take(stemLength))
      .replaceAll(_trailingDotsAndSpaces, '');
  return '$stem$extension';
}

/// Determines an image extension from the URL path without being confused by
/// query strings. Unknown or malformed URLs deliberately fall back to JPEG.
String inferImageFileExtension(String url) {
  try {
    final path = Uri.parse(url).path.toLowerCase();
    for (final extension in const ['.png', '.jpg', '.jpeg', '.webp', '.gif']) {
      if (path.endsWith(extension)) {
        return extension == '.jpeg' ? '.jpg' : extension;
      }
    }
  } on FormatException {
    // Fall through to the format historically used by Pixiv originals.
  }
  return '.jpg';
}
