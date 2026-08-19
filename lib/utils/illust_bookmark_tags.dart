List<String> normalizeIllustBookmarkTags(Iterable<String>? tags) {
  if (tags == null) return const <String>[];

  final normalized = <String>[];
  final seen = <String>{};
  for (final rawTag in tags) {
    final tag = rawTag.trim();
    if (tag.isNotEmpty && seen.add(tag)) {
      normalized.add(tag);
    }
  }
  return normalized;
}

String? encodeIllustBookmarkTags(Iterable<String>? tags) {
  final normalized = normalizeIllustBookmarkTags(tags);
  return normalized.isEmpty ? null : normalized.join(' ');
}
