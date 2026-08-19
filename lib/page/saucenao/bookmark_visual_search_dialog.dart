import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:pixez/utils/bookmark_visual_search.dart';
import 'package:pixez/utils/pixiv_bookmark_visual_search.dart';

enum BookmarkSearchChoice { scanBookmarks, useExternalProviders, cancel }

enum BookmarkVisualCandidateDecisionType {
  selected,
  continueScanning,
  useExternalProviders,
}

class BookmarkVisualCandidateDecision {
  final BookmarkVisualCandidateDecisionType type;
  final BookmarkVisualCandidate? candidate;

  const BookmarkVisualCandidateDecision._(this.type, [this.candidate]);

  const BookmarkVisualCandidateDecision.selected(
    BookmarkVisualCandidate candidate,
  ) : this._(BookmarkVisualCandidateDecisionType.selected, candidate);

  const BookmarkVisualCandidateDecision.continueScanning()
    : this._(BookmarkVisualCandidateDecisionType.continueScanning);

  const BookmarkVisualCandidateDecision.useExternalProviders()
    : this._(BookmarkVisualCandidateDecisionType.useExternalProviders);
}

Future<BookmarkSearchChoice> showBookmarkSearchChoiceDialog(
  BuildContext context,
) async {
  final chinese = Localizations.localeOf(context).languageCode == 'zh';
  final title = chinese ? '先在我的收藏中查找？' : 'Search my bookmarks first?';
  final message = chinese
      ? '本地无法找到这张图的来源。可以先下载当前Pixiv账号的公开和非公开收藏预览图，在手机上做视觉比对。'
      : 'No local source was found. PixEz can download previews from the '
            'currently selected account\'s public and private bookmarks and '
            'compare them on this device.';
  final warning = chinese
      ? '注意：扫描大量收藏会使用网络流量！'
      : 'Warning: scanning many bookmarks uses network data.';
  Widget content(BuildContext dialogContext) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(message),
      const SizedBox(height: 12),
      Text(
        warning,
        style: TextStyle(
          color: Theme.of(dialogContext).colorScheme.error,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );

  if (Platform.isWindows) {
    return await fluent.showDialog<BookmarkSearchChoice>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => fluent.ContentDialog(
            title: Text(title),
            content: content(dialogContext),
            actions: [
              fluent.Button(
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(BookmarkSearchChoice.cancel),
                child: Text(chinese ? '取消' : 'Cancel'),
              ),
              fluent.Button(
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(BookmarkSearchChoice.useExternalProviders),
                child: Text(chinese ? '直接用外部识图' : 'Use external search'),
              ),
              fluent.FilledButton(
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(BookmarkSearchChoice.scanBookmarks),
                child: Text(chinese ? '扫描我的收藏' : 'Scan my bookmarks'),
              ),
            ],
          ),
        ) ??
        BookmarkSearchChoice.cancel;
  }

  return await showDialog<BookmarkSearchChoice>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: content(dialogContext),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(BookmarkSearchChoice.cancel),
              child: Text(chinese ? '取消' : 'Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(BookmarkSearchChoice.useExternalProviders),
              child: Text(chinese ? '直接用外部识图' : 'Use external search'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(BookmarkSearchChoice.scanBookmarks),
              child: Text(chinese ? '扫描我的收藏' : 'Scan my bookmarks'),
            ),
          ],
        ),
      ) ??
      BookmarkSearchChoice.cancel;
}

Future<BookmarkVisualSearchResult?> showBookmarkVisualSearchProgressDialog({
  required BuildContext context,
  required PixivBookmarkVisualSearchController controller,
  required Uint8List queryBytes,
  String? queryFileName,
}) {
  final dialog = _BookmarkSearchProgressDialog(
    controller: controller,
    queryBytes: queryBytes,
    queryFileName: queryFileName,
  );
  if (Platform.isWindows) {
    return fluent.showDialog<BookmarkVisualSearchResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => dialog,
    );
  }
  return showDialog<BookmarkVisualSearchResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => dialog,
  );
}

class _BookmarkSearchProgressDialog extends StatefulWidget {
  final PixivBookmarkVisualSearchController controller;
  final Uint8List queryBytes;
  final String? queryFileName;

  const _BookmarkSearchProgressDialog({
    required this.controller,
    required this.queryBytes,
    this.queryFileName,
  });

  @override
  State<_BookmarkSearchProgressDialog> createState() =>
      _BookmarkSearchProgressDialogState();
}

class _BookmarkSearchProgressDialogState
    extends State<_BookmarkSearchProgressDialog> {
  BookmarkVisualProgress _progress = const BookmarkVisualProgress();
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final result = await widget.controller.search(
      queryBytes: widget.queryBytes,
      queryFileName: widget.queryFileName,
      onProgress: (progress) {
        if (!mounted) return;
        setState(() => _progress = progress);
      },
    );
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  void _cancel() {
    if (_cancelling) return;
    setState(() => _cancelling = true);
    widget.controller.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final visibility = switch (_progress.visibility) {
      BookmarkVisibility.public => chinese ? '公开收藏' : 'public bookmarks',
      BookmarkVisibility.private => chinese ? '非公开收藏' : 'private bookmarks',
      null => chinese ? '准备中' : 'preparing',
    };
    final details = chinese
        ? '$visibility\n已读取 ${_progress.pagesLoaded} 页 · '
              '${_progress.imagesCompared}/${_progress.imagesScheduled} 张图\n'
              '候选 ${_progress.candidateCount} · 读取失败 ${_progress.imageFailures}'
        : '$visibility\n${_progress.pagesLoaded} pages · '
              '${_progress.imagesCompared}/${_progress.imagesScheduled} images\n'
              '${_progress.candidateCount} candidates · '
              '${_progress.imageFailures} read failures';

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LinearProgressIndicator(),
        const SizedBox(height: 14),
        Text(details),
        const SizedBox(height: 8),
        Text(
          chinese
              ? '公开和非公开收藏会逐页交替扫描；找到完全一致的视觉候选后会立即停止。'
              : 'Public and private pages are scanned alternately. The scan '
                    'stops as soon as an exact visual candidate is found.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );

    return PopScope(
      canPop: false,
      child: Platform.isWindows
          ? fluent.ContentDialog(
              title: Text(chinese ? '正在我的收藏中查找' : 'Searching my bookmarks'),
              content: content,
              actions: [
                fluent.Button(
                  onPressed: _cancelling ? null : _cancel,
                  child: Text(
                    _cancelling
                        ? (chinese ? '正在取消' : 'Cancelling')
                        : (chinese ? '取消扫描' : 'Cancel scan'),
                  ),
                ),
              ],
            )
          : AlertDialog(
              title: Text(chinese ? '正在我的收藏中查找' : 'Searching my bookmarks'),
              content: content,
              actions: [
                TextButton(
                  onPressed: _cancelling ? null : _cancel,
                  child: Text(
                    _cancelling
                        ? (chinese ? '正在取消' : 'Cancelling')
                        : (chinese ? '取消扫描' : 'Cancel scan'),
                  ),
                ),
              ],
            ),
    );
  }
}

Future<BookmarkVisualCandidateDecision> showBookmarkVisualCandidatesDialog({
  required BuildContext context,
  required BookmarkVisualSearchResult result,
  required Uint8List queryBytes,
  required PixivBookmarkVisualSearchController controller,
}) async {
  final candidates = <BookmarkVisualCandidate>[];
  final seen = <int>{};
  final match = result.match;
  if (match != null && seen.add(match.illustId)) candidates.add(match);
  for (final candidate in result.candidates) {
    if (seen.add(candidate.illustId)) candidates.add(candidate);
    if (candidates.length >= 5) break;
  }
  if (candidates.isEmpty) {
    return const BookmarkVisualCandidateDecision.useExternalProviders();
  }

  final chinese = Localizations.localeOf(context).languageCode == 'zh';
  final title = chinese ? '收藏中的视觉候选' : 'Visual candidates in bookmarks';
  final message = chinese
      ? 'dHash 会对缩放和重新压缩保持稳定，但它不能单独证明原作。请对照缩略图，只有确认后才会记住这个来源。'
      : 'dHash is stable under resize and recompression, but it is not proof '
            'of authorship. Compare the preview; the source is cached only '
            'after you confirm it.';

  final candidatePreviews = <String, Future<Uint8List?>>{
    for (final candidate in candidates)
      '${candidate.illustId}:${candidate.pageIndex}': controller
          .loadCandidatePreview(candidate),
  };

  Future<Uint8List?> previewFuture(BookmarkVisualCandidate candidate) =>
      candidatePreviews['${candidate.illustId}:${candidate.pageIndex}']!;

  var confirmationInProgress = false;
  Future<bool> confirmCandidate(
    BuildContext dialogContext,
    BookmarkVisualCandidate candidate,
  ) async {
    if (confirmationInProgress) return false;
    confirmationInProgress = true;
    try {
      return await _confirmBookmarkVisualCandidate(
        context: dialogContext,
        queryBytes: queryBytes,
        candidate: candidate,
        candidatePreviewBytes: previewFuture(candidate),
      );
    } finally {
      confirmationInProgress = false;
    }
  }

  Widget preview(BookmarkVisualCandidate candidate) => SizedBox(
    width: 84,
    height: 84,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: FutureBuilder<Uint8List?>(
        future: previewFuture(candidate),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null) {
            return const ColoredBox(
              color: Colors.black12,
              child: Center(child: Icon(Icons.image_outlined)),
            );
          }
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            cacheWidth: 252,
            errorBuilder: (_, _, _) => const ColoredBox(
              color: Colors.black12,
              child: Center(child: Icon(Icons.broken_image_outlined)),
            ),
          );
        },
      ),
    ),
  );

  String subtitle(BookmarkVisualCandidate candidate) {
    final scope = candidate.visibility == BookmarkVisibility.private
        ? (chinese ? '非公开收藏' : 'Private bookmark')
        : (chinese ? '公开收藏' : 'Public bookmark');
    final distance = candidate.distance == null
        ? (chinese ? '字节完全一致' : 'Exact bytes')
        : 'dHash ${candidate.distance}/64';
    return '$scope · $distance · p${candidate.pageIndex}';
  }

  if (Platform.isWindows) {
    return await fluent.showDialog<BookmarkVisualCandidateDecision>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => fluent.ContentDialog(
            title: Text(title),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 470),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(message),
                    const SizedBox(height: 10),
                    ...candidates.map(
                      (candidate) => fluent.ListTile(
                        leading: preview(candidate),
                        title: Text('Pixiv #${candidate.illustId}'),
                        subtitle: Text(subtitle(candidate)),
                        onPressed: () async {
                          final accepted = await confirmCandidate(
                            dialogContext,
                            candidate,
                          );
                          if (accepted && dialogContext.mounted) {
                            Navigator.of(dialogContext).pop(
                              BookmarkVisualCandidateDecision.selected(
                                candidate,
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              if (result.status == BookmarkVisualSearchStatus.matched &&
                  !result.scanComplete)
                fluent.Button(
                  onPressed: () => Navigator.of(dialogContext).pop(
                    const BookmarkVisualCandidateDecision.continueScanning(),
                  ),
                  child: Text(
                    chinese ? '候选不对，继续扫描收藏' : 'Wrong match, keep scanning',
                  ),
                ),
              fluent.Button(
                onPressed: () => Navigator.of(dialogContext).pop(
                  const BookmarkVisualCandidateDecision.useExternalProviders(),
                ),
                child: Text(chinese ? '继续外部识图' : 'Continue externally'),
              ),
            ],
          ),
        ) ??
        const BookmarkVisualCandidateDecision.useExternalProviders();
  }

  return await showDialog<BookmarkVisualCandidateDecision>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 470),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(message),
                  const SizedBox(height: 10),
                  ...candidates.map(
                    (candidate) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: preview(candidate),
                      title: Text('Pixiv #${candidate.illustId}'),
                      subtitle: Text(subtitle(candidate)),
                      onTap: () async {
                        final accepted = await confirmCandidate(
                          dialogContext,
                          candidate,
                        );
                        if (accepted && dialogContext.mounted) {
                          Navigator.of(dialogContext).pop(
                            BookmarkVisualCandidateDecision.selected(candidate),
                          );
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (result.status == BookmarkVisualSearchStatus.matched &&
                !result.scanComplete)
              TextButton(
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(const BookmarkVisualCandidateDecision.continueScanning()),
                child: Text(
                  chinese ? '候选不对，继续扫描收藏' : 'Wrong match, keep scanning',
                ),
              ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                const BookmarkVisualCandidateDecision.useExternalProviders(),
              ),
              child: Text(chinese ? '继续外部识图' : 'Continue externally'),
            ),
          ],
        ),
      ) ??
      const BookmarkVisualCandidateDecision.useExternalProviders();
}

Future<bool> _confirmBookmarkVisualCandidate({
  required BuildContext context,
  required Uint8List queryBytes,
  required BookmarkVisualCandidate candidate,
  required Future<Uint8List?> candidatePreviewBytes,
}) async {
  final resolvedCandidatePreview = await candidatePreviewBytes;
  if (!context.mounted) return false;
  final chinese = Localizations.localeOf(context).languageCode == 'zh';
  final queryPreview = ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: SizedBox(
      width: 132,
      height: 132,
      child: Image.memory(
        queryBytes,
        fit: BoxFit.contain,
        cacheWidth: 396,
        errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black12),
      ),
    ),
  );
  final candidatePreview = ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: SizedBox(
      width: 132,
      height: 132,
      child: resolvedCandidatePreview == null
          ? ColoredBox(
              color: Colors.black12,
              child: Center(
                child: Text(chinese ? '候选预览加载失败' : 'Preview unavailable'),
              ),
            )
          : Image.memory(
              resolvedCandidatePreview,
              fit: BoxFit.contain,
              cacheWidth: 396,
              errorBuilder: (_, _, _) => const ColoredBox(
                color: Colors.black12,
                child: Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
    ),
  );
  final comparison = Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        chinese
            ? '请确认两张图确实来自同一作品。确认后，这张查询图会在本机记为 Pixiv #${candidate.illustId}。'
            : 'Confirm that both images are from the same work. The query '
                  'image will then be remembered locally as Pixiv '
                  '#${candidate.illustId}.',
      ),
      const SizedBox(height: 14),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(chinese ? '查询图' : 'Query'),
              const SizedBox(height: 6),
              queryPreview,
            ],
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Pixiv #${candidate.illustId}'),
              const SizedBox(height: 6),
              candidatePreview,
            ],
          ),
        ],
      ),
    ],
  );

  if (Platform.isWindows) {
    return await fluent.showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => fluent.ContentDialog(
            title: Text(chinese ? '确认视觉候选' : 'Confirm visual candidate'),
            content: comparison,
            actions: [
              fluent.Button(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(chinese ? '返回' : 'Back'),
              ),
              fluent.FilledButton(
                onPressed: resolvedCandidatePreview == null
                    ? null
                    : () => Navigator.of(dialogContext).pop(true),
                child: Text(chinese ? '确认并记住' : 'Confirm and remember'),
              ),
            ],
          ),
        ) ??
        false;
  }

  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(chinese ? '确认视觉候选' : 'Confirm visual candidate'),
          content: SingleChildScrollView(child: comparison),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(chinese ? '返回' : 'Back'),
            ),
            FilledButton(
              onPressed: resolvedCandidatePreview == null
                  ? null
                  : () => Navigator.of(dialogContext).pop(true),
              child: Text(chinese ? '确认并记住' : 'Confirm and remember'),
            ),
          ],
        ),
      ) ??
      false;
}
