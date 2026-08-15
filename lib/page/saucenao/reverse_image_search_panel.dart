import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/custom_tab_plugin.dart';
import 'package:pixez/page/picture/illust_lighting_page.dart';
import 'package:pixez/page/saucenao/sauce_store.dart';
import 'package:pixez/utils/reverse_image_search.dart';
import 'package:pixez/utils/reverse_image_session.dart';

class ReverseImageSearchPanel extends StatefulWidget {
  final SauceStore store;

  const ReverseImageSearchPanel({super.key, required this.store});

  @override
  State<ReverseImageSearchPanel> createState() =>
      _ReverseImageSearchPanelState();
}

class _ReverseImageSearchPanelState extends State<ReverseImageSearchPanel>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();
  Timer? _elapsedTimer;

  bool get _isChinese =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'zh';

  String _text(String chinese, String english) =>
      _isChinese ? chinese : english;

  @override
  void initState() {
    super.initState();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.store.searchBusy.value) setState(() {});
    });
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Observer(
      builder: (context) {
        final bytes = widget.store.selectedImageBytes.value;
        final busy = widget.store.searchBusy.value;
        final candidates = widget.store.sessionCandidates.toList(
          growable: false,
        );
        final steps = widget.store.sessionSteps.toList(growable: false);
        final messages = widget.store.serviceMessages.toList(growable: false);
        return CustomScrollView(
          key: const PageStorageKey<String>('reverse_image_search_scroll'),
          controller: _scrollController,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(
                child: _buildStartCard(context, bytes, busy),
              ),
            ),
            if (steps.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                sliver: SliverToBoxAdapter(
                  child: _buildProgressCard(context, steps),
                ),
              ),
            if (bytes != null && !busy)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                sliver: SliverToBoxAdapter(child: _buildActions(context)),
              ),
            if (messages.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                sliver: SliverToBoxAdapter(
                  child: _buildServiceMessages(context, messages),
                ),
              ),
            if (candidates.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          busy
                              ? _text(
                                  '已找到 ${candidates.length} 个候选，其他服务仍在搜索',
                                  '${candidates.length} candidate(s) found; '
                                      'other providers are still searching',
                                )
                              : _text(
                                  '本次保留的候选（${candidates.length}）',
                                  'Candidates retained (${candidates.length})',
                                ),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      const Icon(Icons.fact_check_outlined),
                    ],
                  ),
                ),
              ),
            if (candidates.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    _text(
                      '候选按相似度与多服务/多区域证据排序，不代表作者身份已经确认。进入作品后返回，列表会保留。',
                      'Candidates are ranked by similarity and independent evidence; '
                          'they do not prove authorship. The list remains after you return.',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            if (candidates.isNotEmpty)
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => Padding(
                    padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
                    child: _buildCandidateCard(context, candidates[index]),
                  ),
                  childCount: candidates.length,
                ),
              ),
            if (bytes != null && !busy && candidates.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                sliver: SliverToBoxAdapter(child: _buildEmptyState(context)),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        );
      },
    );
  }

  Widget _buildStartCard(BuildContext context, Uint8List? bytes, bool busy) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colors.surfaceContainer,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (bytes != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      bytes,
                      width: 104,
                      height: 104,
                      cacheWidth: 312,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _imagePlaceholder(context),
                    ),
                  )
                else
                  _imagePlaceholder(context),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bytes == null
                            ? _text('独立识图', 'Image source search')
                            : (widget.store.selectedFileName.value ??
                                  _text('已选择图片', 'Image selected')),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        bytes == null
                            ? _text(
                                '先检查本地 PID/下载指纹，再并行查询 SauceNAO 与 IQDB。不会自动扫描收藏，以免把快速识图拖到几分钟。',
                                'Checks local identity first, then searches SauceNAO and '
                                    'IQDB in parallel. Bookmarks are a separate optional scan.',
                              )
                            : _phaseSummary(widget.store.phase.value),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (widget.store.sessionStartedAt != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _text('耗时 ', 'Elapsed ') +
                              _formatDuration(widget.store.sessionElapsed),
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (busy)
              const LinearProgressIndicator()
            else
              const SizedBox.shrink(),
            if (busy) const SizedBox(height: 12),
            if (busy && widget.store.canCancelSearch) ...[
              OutlinedButton.icon(
                key: const Key('reverse_image_cancel_action'),
                onPressed: widget.store.cancelCurrentSearch,
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(_text('取消当前查询', 'Cancel current search')),
              ),
              const SizedBox(height: 8),
            ],
            FilledButton.icon(
              key: const Key('reverse_image_pick_action'),
              onPressed: busy
                  ? null
                  : () => widget.store.findImage(
                      context: context,
                      inlineResults: true,
                      skipBookmarkPrompt: true,
                    ),
              icon: Icon(
                bytes == null ? Icons.add_photo_alternate : Icons.refresh,
              ),
              label: Text(
                bytes == null
                    ? _text('选择图片并开始', 'Choose image and start')
                    : _text('选择另一张图片', 'Choose another image'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imagePlaceholder(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 104,
      height: 104,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.image_search, size: 42, color: colors.primary),
    );
  }

  Widget _buildProgressCard(
    BuildContext context,
    List<ReverseImageSessionStep> steps,
  ) {
    final visible = steps
        .where(
          (step) =>
              step.state != ReverseImageSessionStepState.pending ||
              step.id == ReverseImageSessionStepId.results,
        )
        .toList(growable: false);
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
              child: Text(
                _text('搜索进度', 'Search progress'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ...visible.map((step) => _buildStepTile(context, step)),
          ],
        ),
      ),
    );
  }

  Widget _buildStepTile(BuildContext context, ReverseImageSessionStep step) {
    final colors = Theme.of(context).colorScheme;
    final running = step.state == ReverseImageSessionStepState.running;
    return ListTile(
      dense: true,
      leading: running
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : Icon(_stepIcon(step.state), color: _stepColor(colors, step.state)),
      title: Text(_stepLabel(step.id)),
      subtitle: _isChinese && step.detail != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_stepStateLabel(step.state)),
                Text(
                  step.detail!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            )
          : Text(step.detail ?? _stepStateLabel(step.state)),
      trailing: step.elapsed == null
          ? null
          : Text(
              _formatDuration(step.elapsed!),
              style: Theme.of(context).textTheme.labelSmall,
            ),
    );
  }

  Widget _buildActions(BuildContext context) {
    final store = widget.store;
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _text('继续查找', 'Search further'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: store.canSearchBookmarks
                      ? () => store.searchSelectedImageInBookmarks(context)
                      : null,
                  icon: const Icon(Icons.bookmarks_outlined),
                  label: Text(_text('扫描我的收藏', 'Scan my bookmarks')),
                ),
                if (store.canOpenAscii2d)
                  OutlinedButton.icon(
                    onPressed: () => store.openAscii2dForCurrentImage(context),
                    icon: const Icon(Icons.language),
                    label: const Text('Ascii2D'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _text(
                '只有半张图、拼图或截图时，选择最接近主体的区域。每次只会额外提交你点选的一个区域。',
                'For crops, collages or screenshots, choose the region closest '
                    'to the subject. Only the region you tap is submitted.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _cropAction(context, ReverseImageProbeKind.center, '中央'),
                _cropAction(context, ReverseImageProbeKind.left, '左侧'),
                _cropAction(context, ReverseImageProbeKind.right, '右侧'),
                _cropAction(context, ReverseImageProbeKind.top, '上方'),
                _cropAction(context, ReverseImageProbeKind.bottom, '下方'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _cropAction(
    BuildContext context,
    ReverseImageProbeKind probe,
    String chineseLabel,
  ) {
    return OutlinedButton.icon(
      onPressed: widget.store.canRetryRegion
          ? () => widget.store.retrySelectedRegion(context, probe)
          : null,
      icon: const Icon(Icons.crop),
      label: Text(_isChinese ? chineseLabel : probe.name),
    );
  }

  Widget _buildServiceMessages(BuildContext context, List<String> messages) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _text('部分服务信息', 'Provider notes'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            ...messages.map((message) => Text('• $message')),
          ],
        ),
      ),
    );
  }

  Widget _buildCandidateCard(
    BuildContext context,
    ReverseImageDisplayCandidate candidate,
  ) {
    final colors = Theme.of(context).colorScheme;
    final providers = candidate.providerIds
        .map((id) => id.toUpperCase())
        .join(' + ');
    final probes = candidate.probes
        .map((probe) => _probeLabel(probe))
        .join(' / ');
    final host = Uri.tryParse(candidate.sourceUrl)?.host ?? candidate.sourceUrl;
    return Card(
      key: ValueKey<String>(candidate.candidateId),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openCandidate(context, candidate),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: candidate.thumbnailUrl == null
                    ? _candidatePlaceholder(context)
                    : TrustedProviderThumbnail(url: candidate.thumbnailUrl!),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            candidate.title ?? host,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _confidenceChip(context, candidate.confidence),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${candidate.bestSimilarity.toStringAsFixed(1)}% · $providers',
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: colors.primary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_text('区域', 'Region')}: $probes',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (candidate.evidence.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          _text(
                            '${candidate.evidence.length} 条匹配证据',
                            '${candidate.evidence.length} matching signals',
                          ),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(candidate.isPixiv ? Icons.chevron_right : Icons.open_in_new),
            ],
          ),
        ),
      ),
    );
  }

  Widget _candidatePlaceholder(BuildContext context) => Container(
    width: 96,
    height: 96,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    alignment: Alignment.center,
    child: const Icon(Icons.image_not_supported_outlined, size: 34),
  );

  Widget _confidenceChip(
    BuildContext context,
    ReverseImageCandidateConfidence confidence,
  ) {
    final (label, color) = switch (confidence) {
      ReverseImageCandidateConfidence.high => (
        _text('高可信', 'High'),
        Theme.of(context).colorScheme.primaryContainer,
      ),
      ReverseImageCandidateConfidence.medium => (
        _text('需确认', 'Review'),
        Theme.of(context).colorScheme.secondaryContainer,
      ),
      ReverseImageCandidateConfidence.low => (
        _text('低可信', 'Low'),
        Theme.of(context).colorScheme.tertiaryContainer,
      ),
    };
    return Chip(
      visualDensity: VisualDensity.compact,
      side: BorderSide.none,
      backgroundColor: color,
      label: Text(label),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final error = widget.store.lastError.value;
    final cancelled = widget.store.phase.value == SauceSearchPhase.cancelled;
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              cancelled
                  ? Icons.cancel_outlined
                  : (error == null ? Icons.search_off : Icons.error_outline),
              size: 42,
            ),
            const SizedBox(height: 10),
            Text(
              cancelled
                  ? _text('已取消本次搜索', 'Search cancelled')
                  : (error ?? _text('暂未找到可靠候选', 'No reliable candidate yet')),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              cancelled
                  ? _text(
                      '已保留选中的图片，你可以重新开始或选择其他图片。',
                      'The selected image is retained. Start again or choose '
                          'another image.',
                    )
                  : _text(
                      '你可以扫描自己的收藏、选择主体区域重试，或打开 Ascii2D 的特征搜索。',
                      'You can scan your bookmarks, retry a subject region, or '
                          'use Ascii2D feature search.',
                    ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openCandidate(
    BuildContext context,
    ReverseImageDisplayCandidate candidate,
  ) async {
    final illustId = candidate.illustId;
    if (illustId != null) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => IllustLightingPage(id: illustId)),
      );
      return;
    }
    await CustomTabPlugin.launch(candidate.sourceUrl);
  }

  String _phaseSummary(SauceSearchPhase phase) => switch (phase) {
    SauceSearchPhase.idle => _text('等待开始', 'Ready'),
    SauceSearchPhase.picking => _text('正在选择图片', 'Choosing an image'),
    SauceSearchPhase.inspecting => _text('正在检查本地记录', 'Checking locally'),
    SauceSearchPhase.uploading => _text('正在准备安全副本', 'Preparing upload copy'),
    SauceSearchPhase.parsing => _text('正在查询识图服务', 'Searching providers'),
    SauceSearchPhase.success => _text('搜索完成，可查看候选', 'Search complete'),
    SauceSearchPhase.noResult => _text('搜索完成，未找到可靠候选', 'No reliable match'),
    SauceSearchPhase.cancelled => _text('已取消本次搜索', 'Search cancelled'),
    SauceSearchPhase.error => _text('搜索出现错误', 'Search failed'),
  };

  String _stepLabel(ReverseImageSessionStepId id) => switch (id) {
    ReverseImageSessionStepId.pick => _text('读取图片', 'Read image'),
    ReverseImageSessionStepId.localIdentity => _text(
      '本地 PID / 指纹',
      'Local ID / fingerprint',
    ),
    ReverseImageSessionStepId.bookmarks => _text(
      '我的 Pixiv 收藏',
      'My Pixiv bookmarks',
    ),
    ReverseImageSessionStepId.prepare => _text(
      '去除元数据并缩放',
      'Sanitize upload copy',
    ),
    ReverseImageSessionStepId.sauceNao => 'SauceNAO',
    ReverseImageSessionStepId.iqdb => 'IQDB',
    ReverseImageSessionStepId.results => _text('整理候选', 'Rank candidates'),
    ReverseImageSessionStepId.crop => _text('区域识图', 'Region search'),
  };

  String _probeLabel(ReverseImageProbeKind probe) => switch (probe) {
    ReverseImageProbeKind.full => _text('全图', 'full'),
    ReverseImageProbeKind.center => _text('中央', 'center'),
    ReverseImageProbeKind.left => _text('左侧', 'left'),
    ReverseImageProbeKind.right => _text('右侧', 'right'),
    ReverseImageProbeKind.top => _text('上方', 'top'),
    ReverseImageProbeKind.bottom => _text('下方', 'bottom'),
  };

  String _stepStateLabel(ReverseImageSessionStepState state) => switch (state) {
    ReverseImageSessionStepState.pending => _text('等待中', 'Pending'),
    ReverseImageSessionStepState.running => _text('正在进行', 'In progress'),
    ReverseImageSessionStepState.succeeded => _text('已完成', 'Completed'),
    ReverseImageSessionStepState.noMatch => _text('未找到匹配', 'No match'),
    ReverseImageSessionStepState.failed => _text('服务失败', 'Failed'),
    ReverseImageSessionStepState.skipped => _text('已跳过', 'Skipped'),
    ReverseImageSessionStepState.cancelled => _text('已取消', 'Cancelled'),
  };

  IconData _stepIcon(ReverseImageSessionStepState state) => switch (state) {
    ReverseImageSessionStepState.succeeded => Icons.check_circle,
    ReverseImageSessionStepState.noMatch => Icons.remove_circle_outline,
    ReverseImageSessionStepState.failed => Icons.error,
    ReverseImageSessionStepState.skipped => Icons.skip_next,
    ReverseImageSessionStepState.cancelled => Icons.cancel,
    ReverseImageSessionStepState.pending => Icons.schedule,
    ReverseImageSessionStepState.running => Icons.autorenew,
  };

  Color _stepColor(ColorScheme colors, ReverseImageSessionStepState state) =>
      switch (state) {
        ReverseImageSessionStepState.succeeded => colors.primary,
        ReverseImageSessionStepState.failed => colors.error,
        ReverseImageSessionStepState.cancelled => colors.error,
        ReverseImageSessionStepState.noMatch ||
        ReverseImageSessionStepState.skipped => colors.onSurfaceVariant,
        ReverseImageSessionStepState.pending ||
        ReverseImageSessionStepState.running => colors.secondary,
      };

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return minutes > 0 ? '${minutes}m ${seconds}s' : '${seconds}s';
  }

  @override
  bool get wantKeepAlive => true;
}

class TrustedProviderThumbnail extends StatefulWidget {
  final String url;

  const TrustedProviderThumbnail({super.key, required this.url});

  @override
  State<TrustedProviderThumbnail> createState() =>
      _TrustedProviderThumbnailState();
}

class _TrustedProviderThumbnailState extends State<TrustedProviderThumbnail> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = loadTrustedReverseImageThumbnail(widget.url);
  }

  @override
  void didUpdateWidget(covariant TrustedProviderThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _future = loadTrustedReverseImageThumbnail(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return Image.memory(
            bytes,
            width: 96,
            height: 96,
            cacheWidth: 288,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _placeholder(context),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            width: 96,
            height: 96,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return _placeholder(context);
      },
    );
  }

  Widget _placeholder(BuildContext context) => Container(
    width: 96,
    height: 96,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    alignment: Alignment.center,
    child: const Icon(Icons.image_not_supported_outlined, size: 34),
  );
}

Future<Uint8List?> loadTrustedReverseImageThumbnail(
  String value, {
  int maximumBytes = 2 * 1024 * 1024,
  int maximumRedirects = 3,
}) async {
  Uri? uri = Uri.tryParse(value);
  if (!_isTrustedThumbnailUri(uri)) return null;
  final client = HttpClient()..userAgent = 'PixEz-Archive thumbnail-preview';
  try {
    for (var redirect = 0; redirect <= maximumRedirects; redirect++) {
      final request = await client
          .getUrl(uri!)
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || redirect == maximumRedirects) return null;
        final next = uri.resolve(location);
        if (!_isTrustedThumbnailUri(next)) return null;
        uri = next;
        await response.drain().timeout(const Duration(seconds: 10));
        continue;
      }
      if (response.statusCode != HttpStatus.ok) return null;
      final contentType = response.headers.contentType;
      if (contentType == null || contentType.primaryType != 'image')
        return null;
      final announcedLength = response.contentLength;
      if (announcedLength > maximumBytes) return null;
      final builder = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        length += chunk.length;
        if (length > maximumBytes) return null;
        builder.add(chunk);
      }
      return builder.takeBytes();
    }
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
  return null;
}

bool _isTrustedThumbnailUri(Uri? uri) {
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return host == 'saucenao.com' ||
      host.endsWith('.saucenao.com') ||
      host == 'iqdb.org' ||
      host.endsWith('.iqdb.org');
}
