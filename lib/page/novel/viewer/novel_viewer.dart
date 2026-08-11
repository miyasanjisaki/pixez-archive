/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:mobx/mobx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixez/component/painter_avatar.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/component/selectable_html.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/exts.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/ban_tag.dart';
import 'package:pixez/models/novel_recom_response.dart';
import 'package:pixez/models/novel_web_response.dart';
import 'package:pixez/page/comment/comment_page.dart';
import 'package:pixez/page/novel/component/novel_bookmark_button.dart';
import 'package:pixez/page/novel/search/novel_result_page.dart';
import 'package:pixez/page/novel/series/novel_series_page.dart';
import 'package:pixez/page/novel/user/novel_users_page.dart';
import 'package:pixez/page/novel/viewer/image_text.dart';
import 'package:pixez/page/novel/viewer/novel_store.dart';
import 'package:pixez/saf_plugin.dart';
import 'package:pixez/supportor_plugin.dart';
import 'package:pixez/utils/novel_reader_options.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as Path;

class NovelViewerPage extends StatefulWidget {
  final int id;
  final NovelStore? novelStore;

  const NovelViewerPage({Key? key, required this.id, this.novelStore})
    : super(key: key);

  @override
  _NovelViewerPageState createState() => _NovelViewerPageState();
}

class _NovelViewerPageState extends State<NovelViewerPage> {
  ScrollController? _controller;
  late NovelStore _novelStore;
  ReactionDisposer? _offsetDisposer;
  double _localOffset = 0.0;
  final ValueNotifier<double> _readingProgress = ValueNotifier(0);
  double? _pendingLayoutProgress;
  bool _layoutRestoreScheduled = false;
  bool supportTranslate = false;
  String _selectedText = "";
  NovelSpansGenerator novelSpansGenerator = NovelSpansGenerator();

  Future<void> initMethod() async {
    if (!Platform.isAndroid) return;
    bool results = await SupportorPlugin.processText();
    if (mounted) {
      setState(() {
        supportTranslate = results;
      });
    }
  }

  @override
  void initState() {
    _novelStore = widget.novelStore ?? NovelStore(widget.id, null);
    _offsetDisposer = reaction(
      (_) => (
        _novelStore.positionBooked,
        _novelStore.bookedOffset,
        _novelStore.bookedProgress,
      ),
      (savedPosition) {
        if (!savedPosition.$1) return;
        LPrinter.d("jump to ${savedPosition.$2} progress=${savedPosition.$3}");
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final controller = _controller;
          if (!mounted || controller == null || !controller.hasClients) return;
          final targetOffset = savedPosition.$3 == null
              ? savedPosition.$2
              : controller.position.maxScrollExtent * savedPosition.$3!;
          final target = targetOffset.clamp(
            controller.position.minScrollExtent,
            controller.position.maxScrollExtent,
          );
          controller.jumpTo(target.toDouble());
        });
      },
    );
    _novelStore.fetch();
    super.initState();
    initMethod();
  }

  @override
  void dispose() {
    _offsetDisposer?.call();
    if (_novelStore.positionBooked) {
      _novelStore.bookPosition(_localOffset, progress: _readingProgress.value);
    }
    _controller?.dispose();
    _readingProgress.dispose();
    super.dispose();
  }

  TextStyle? _textStyle;

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        _textStyle = Theme.of(context).textTheme.bodyLarge!.copyWith(
          fontSize: userSetting.novelFontsize,
          height: userSetting.novelLineHeight,
        );
        if (_novelStore.errorMessage != null) {
          return _buildErrorContent(context);
        }
        if (_novelStore.novelTextResponse != null &&
            _novelStore.novel != null) {
          _textStyle =
              _textStyle ?? Theme.of(context).textTheme.bodyLarge!.copyWith();
          if (_controller == null) {
            LPrinter.d("init Controller ${_novelStore.bookedOffset}");
            _controller = ScrollController(
              initialScrollOffset: _novelStore.bookedOffset,
            );
            _controller?.addListener(_handleScroll);
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _handleScroll();
          });
          return Scaffold(
            appBar: _buildAppbar(context),
            body: _buildBody(context),
          );
        }
        return Scaffold(
          appBar: AppBar(elevation: 0.0, backgroundColor: Colors.transparent),
          body: Container(child: Center(child: CircularProgressIndicator())),
        );
      },
    );
  }

  void _handleScroll() {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;
    _localOffset = controller.offset;
    final progress = calculateNovelReadingProgress(
      offset: controller.offset,
      maxScrollExtent: controller.position.maxScrollExtent,
    );
    if ((progress - _readingProgress.value).abs() >= 0.001) {
      _readingProgress.value = progress;
    }
  }

  void _preserveProgressForLayoutChange(VoidCallback change) {
    final controller = _controller;
    _pendingLayoutProgress = controller != null && controller.hasClients
        ? calculateNovelReadingProgress(
            offset: controller.offset,
            maxScrollExtent: controller.position.maxScrollExtent,
          )
        : _readingProgress.value;
    change();
    if (_layoutRestoreScheduled) return;
    _layoutRestoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutRestoreScheduled = false;
      final progress = _pendingLayoutProgress;
      _pendingLayoutProgress = null;
      final activeController = _controller;
      if (!mounted ||
          progress == null ||
          activeController == null ||
          !activeController.hasClients) {
        return;
      }
      final target = activeController.position.maxScrollExtent * progress;
      activeController.jumpTo(
        target
            .clamp(
              activeController.position.minScrollExtent,
              activeController.position.maxScrollExtent,
            )
            .toDouble(),
      );
      _handleScroll();
    });
  }

  Scaffold _buildErrorContent(BuildContext context) {
    return Scaffold(
      appBar: AppBar(elevation: 0.0),
      body: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Container(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Center(
                  child: Text(
                    ':(',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                _novelStore.fetch();
              },
              child: Text(I18n.of(context).retry),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text('${_novelStore.errorMessage}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return SafeArea(
      top: false,
      child: ListView.builder(
        padding: EdgeInsets.zero,
        controller: _controller,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildHeader(context);
          } else if (index == _novelStore.spans.length + 1) {
            return _buildCommentButton(context);
          } else if (index == _novelStore.spans.length + 2) {
            return _buildSeriesNavigation(context);
          } else if (index == _novelStore.spans.length + 3) {
            return const SizedBox(height: 24);
          } else {
            return _buildSpanText(context, index - 1, _novelStore.spans);
          }
        },
        itemCount: 4 + _novelStore.spans.length,
      ),
    );
  }

  AppBar _buildAppbar(BuildContext context) {
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 1,
      leading: IconButton(
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: Text(
        _novelStore.novel!.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: <Widget>[
        NovelBookmarkButton(novel: _novelStore.novel!),
        IconButton(
          tooltip: _novelStore.positionBooked
              ? I18n.of(context).clear_reading_position
              : I18n.of(context).save_reading_position,
          onPressed: () {
            if (_novelStore.positionBooked)
              _novelStore.deleteBookPosition();
            else
              _novelStore.bookPosition(
                _controller?.offset ?? 0,
                progress: _readingProgress.value,
              );
          },
          icon: Icon(
            _novelStore.positionBooked
                ? Icons.bookmark_added
                : Icons.bookmark_add_outlined,
          ),
        ),
        Builder(
          builder: (context) {
            return IconButton(
              tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showMessage(context),
            );
          },
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(24),
        child: ValueListenableBuilder<double>(
          valueListenable: _readingProgress,
          builder: (context, progress, _) {
            final percent = (progress * 100).round();
            return Semantics(
              label: '${I18n.of(context).reading_progress} $percent%',
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
                child: Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 36,
                      child: Text(
                        '$percent%',
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSpanText(
    BuildContext context,
    int index,
    List<NovelSpansData> spanDatas,
  ) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: MediaQuery.sizeOf(context).width >= 600 ? 32 : 20,
          ),
          child: SelectionArea(
            onSelectionChanged: (value) {
              _selectedText = value?.plainText ?? "";
            },
            contextMenuBuilder: (context, editableTextState) {
              return _buildSelectionMenu(editableTextState, context);
            },
            child: Text.rich(
              novelSpansGenerator.novelSpansDatatoInlineSpan(
                context,
                spanDatas[index],
              ),
              style: _textStyle,
              textHeightBehavior: const TextHeightBehavior(
                applyHeightToFirstAscent: false,
                applyHeightToLastDescent: true,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCommentButton(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 16.0, horizontal: 16.0),
      child: Center(
        child: TextButton(
          onPressed: () {
            Leader.push(
              context,
              CommentPage(id: _novelStore.id, type: CommentArtWorkType.NOVEL),
            );
          },
          child: Text(
            '${I18n.of(context).view_comment}(${_novelStore.novel?.totalComments ?? 0})',
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          children: [
            const SizedBox(height: 24),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 160,
                width: 114,
                child: PixivImage(
                  _novelStore.novel!.imageUrls.medium,
                  width: 114,
                  height: 160,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                _novelStore.novel!.title,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (_novelStore.novel?.series.id != null)
              TextButton.icon(
                onPressed: () => Leader.push(
                  context,
                  NovelSeriesPage(_novelStore.novel!.series.id!),
                ),
                icon: const Icon(Icons.library_books_outlined, size: 18),
                label: Text(
                  _novelStore.novel!.series.title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            _buildNumItem(_novelStore.novel!),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _novelStore.novel!.createDate
                    .toLocal()
                    .toString()
                    .split(' ')
                    .first,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (_novelStore.novel!.NovelAIType == 2)
                    Text(
                      I18n.of(context).ai_generated,
                      style: Theme.of(context).textTheme.bodySmall!.copyWith(
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  for (var tag in _novelStore.novel!.tags)
                    buildRow(context, tag),
                ],
              ),
            ),
            if (_novelStore.novel!.caption.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Card(
                  elevation: 0,
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectionArea(
                      onSelectionChanged: (value) {
                        _selectedText = value?.plainText ?? '';
                      },
                      contextMenuBuilder: (context, editableTextState) {
                        return _buildSelectionMenu(editableTextState, context);
                      },
                      child: SelectableHtml(data: _novelStore.novel!.caption),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeriesNavigation(BuildContext context) {
    final navigation = _novelStore.novelTextResponse?.seriesNavigation;
    if (navigation == null) return const SizedBox.shrink();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: _buildSeriesButton(
                  context,
                  series: navigation.prevNovel,
                  label: I18n.of(context).pre,
                  icon: Icons.arrow_back,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildSeriesButton(
                  context,
                  series: navigation.nextNovel,
                  label: I18n.of(context).next,
                  icon: Icons.arrow_forward,
                  iconAfterLabel: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSeriesButton(
    BuildContext context, {
    required PrevNovel? series,
    required String label,
    required IconData icon,
    bool iconAfterLabel = false,
  }) {
    final title = series?.title ?? series?.contentOrder;
    final enabled = series?.viewable == true;
    final children = <Widget>[
      Icon(icon, size: 18),
      const SizedBox(width: 6),
      Flexible(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ];
    return OutlinedButton(
      onPressed: enabled ? () => _replaceWithSeriesNovel(series!) : null,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: iconAfterLabel ? children.reversed.toList() : children,
          ),
          if (title != null) ...[
            const SizedBox(height: 3),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ],
      ),
    );
  }

  void _replaceWithSeriesNovel(PrevNovel series) {
    Navigator.of(context, rootNavigator: true).pushReplacement(
      MaterialPageRoute(
        builder: (context) => NovelViewerPage(
          id: series.id,
          novelStore: NovelStore(series.id, null),
        ),
      ),
    );
  }

  AdaptiveTextSelectionToolbar _buildSelectionMenu(
    SelectableRegionState editableTextState,
    BuildContext context,
  ) {
    final List<ContextMenuButtonItem> buttonItems =
        editableTextState.contextMenuButtonItems;
    if (supportTranslate) {
      buttonItems.insert(
        buttonItems.length,
        ContextMenuButtonItem(
          label: I18n.of(context).translate,
          onPressed: () async {
            final selectionText = _selectedText;
            if (Platform.isIOS) {
              final box = context.findRenderObject() as RenderBox?;
              final pos = box != null
                  ? box.localToGlobal(Offset.zero) & box.size
                  : null;
              SharePlus.instance.share(
                ShareParams(text: selectionText, sharePositionOrigin: pos),
              );
              return;
            }
            await SupportorPlugin.start(selectionText);
            ContextMenuController.removeAny();
          },
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  Future<void> _showSettings(BuildContext context) async {
    var fontSize = clampNovelFontSize(userSetting.novelFontsize);
    var lineHeight = clampNovelLineHeight(userSetting.novelLineHeight);
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setB) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            I18n.of(context).reading_settings,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            setB(() {
                              fontSize = defaultNovelFontSize;
                              lineHeight = defaultNovelLineHeight;
                            });
                            _preserveProgressForLayoutChange(() {
                              userSetting.setNovelFontsizeWithoutSave(fontSize);
                              userSetting.setNovelLineHeightWithoutSave(
                                lineHeight,
                              );
                            });
                          },
                          child: Text(I18n.of(context).reset),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Card(
                      elevation: 0,
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          I18n.of(context).reader_preview,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                fontSize: fontSize,
                                height: lineHeight,
                              ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildReaderSlider(
                      context,
                      icon: Icons.text_fields,
                      label: I18n.of(context).font_size,
                      valueLabel: fontSize.round().toString(),
                      value: fontSize,
                      min: minNovelFontSize,
                      max: maxNovelFontSize,
                      divisions: 20,
                      onChanged: (value) {
                        setB(() => fontSize = clampNovelFontSize(value));
                        _preserveProgressForLayoutChange(
                          () =>
                              userSetting.setNovelFontsizeWithoutSave(fontSize),
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    _buildReaderSlider(
                      context,
                      icon: Icons.format_line_spacing,
                      label: I18n.of(context).line_spacing,
                      valueLabel: lineHeight.toStringAsFixed(1),
                      value: lineHeight,
                      min: minNovelLineHeight,
                      max: maxNovelLineHeight,
                      divisions: 9,
                      step: 0.1,
                      onChanged: (value) {
                        setB(() => lineHeight = clampNovelLineHeight(value));
                        _preserveProgressForLayoutChange(
                          () => userSetting.setNovelLineHeightWithoutSave(
                            lineHeight,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    await userSetting.setNovelFontsize(fontSize);
    await userSetting.setNovelLineHeight(lineHeight);
  }

  Widget _buildReaderSlider(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required int divisions,
    double step = 1,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      children: [
        Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.titleSmall),
            ),
            Text(valueLabel, style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
        Row(
          children: [
            IconButton(
              tooltip: '$label -',
              onPressed: value > min ? () => onChanged(value - step) : null,
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: Slider(
                value: value.clamp(min, max).toDouble(),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
            IconButton(
              tooltip: '$label +',
              onPressed: value < max ? () => onChanged(value + step) : null,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ],
    );
  }

  Future _longPressTag(BuildContext context, Tag f) async {
    switch (await showDialog(
      context: context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: Text(f.name),
          children: <Widget>[
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context, 0);
              },
              child: Text(I18n.of(context).ban),
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context, 2);
              },
              child: Text(I18n.of(context).copy),
            ),
          ],
        );
      },
    )) {
      case 0:
        {
          await muteStore.insertBanTag(
            BanTagPersist(name: f.name, translateName: f.translatedName ?? ""),
          );
          Navigator.of(context).pop();
        }
        break;
      case 2:
        {
          await Clipboard.setData(ClipboardData(text: f.name));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: Duration(seconds: 1),
              content: Text(I18n.of(context).copied_to_clipboard),
            ),
          );
        }
    }
  }

  Widget buildRow(BuildContext context, Tag f) {
    return GestureDetector(
      onLongPress: () async {
        _longPressTag(context, f);
      },
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) {
              return NovelResultPage(
                word: f.name,
                translatedName: f.translatedName ?? "",
              );
            },
          ),
        );
      },
      child: RichText(
        textAlign: TextAlign.center,
        text: TextSpan(
          text: "#${f.name}",
          children: [
            TextSpan(text: " ", style: Theme.of(context).textTheme.bodySmall),
            TextSpan(
              text: "${f.translatedName ?? "~"}",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          style: Theme.of(context).textTheme.bodySmall!.copyWith(
            color: Theme.of(context).colorScheme.secondary,
          ),
        ),
      ),
    );
  }

  Widget _buildNumItem(Novel novel) {
    final rating = _novelStore.novelTextResponse?.rating;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          if (rating != null)
            _buildDetailMetric(
              icon: Icons.favorite_outline,
              label: I18n.of(context).novel_likes,
              value: rating.like,
            ),
          _buildDetailMetric(
            icon: Icons.bookmark_outline,
            label: I18n.of(context).novel_bookmarks,
            value: rating?.bookmark ?? novel.totalBookmarks,
          ),
          _buildDetailMetric(
            icon: Icons.visibility_outlined,
            label: I18n.of(context).novel_views,
            value: rating?.view ?? novel.totalView,
          ),
        ],
      ),
    );
  }

  Widget _buildDetailMetric({
    required IconData icon,
    required String label,
    required int value,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text('$label $value', style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }

  Future _showMessage(BuildContext pageContext) {
    return showModalBottomSheet(
      context: pageContext,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ListTile(
                subtitle: Text(_novelStore.novel!.user.name, maxLines: 2),
                title: Text(_novelStore.novel!.title, maxLines: 2),
                leading: Container(
                  child: PainterAvatar(
                    url: _novelStore.novel!.user.profileImageUrls.medium,
                    id: _novelStore.novel!.user.id,
                    size: Size(40, 40),
                    onTap: () {
                      Navigator.of(sheetContext).push(
                        MaterialPageRoute(
                          builder: (context) {
                            return NovelUsersPage(
                              id: _novelStore.novel!.user.id,
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(I18n.of(sheetContext).pre),
              ),
              buildListTile(
                sheetContext,
                _novelStore.novelTextResponse!.seriesNavigation?.prevNovel,
              ),
              Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(I18n.of(sheetContext).next),
              ),
              buildListTile(
                sheetContext,
                _novelStore.novelTextResponse!.seriesNavigation?.nextNovel,
              ),
              if (Platform.isAndroid)
                ListTile(
                  title: Text(I18n.of(sheetContext).export),
                  leading: Icon(Icons.folder_zip),
                  onTap: () {
                    _export();
                  },
                ),
              ListTile(
                title: Text(I18n.of(sheetContext).setting),
                leading: Icon(Icons.settings),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _showSettings(pageContext);
                  });
                },
              ),
              Builder(
                builder: (context) {
                  return ListTile(
                    title: Text(I18n.of(sheetContext).share),
                    leading: Icon(Icons.share),
                    onTap: () {
                      final box = sheetContext.findRenderObject() as RenderBox?;
                      final pos = box != null
                          ? box.localToGlobal(Offset.zero) & box.size
                          : null;
                      Navigator.of(sheetContext).pop();
                      final link =
                          "https://www.pixiv.net/novel/show.php?id=${widget.id}";
                      SharePlus.instance.share(
                        ShareParams(text: link, sharePositionOrigin: pos),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget buildListTile(BuildContext sheetContext, PrevNovel? series) {
    if (series == null) {
      return ListTile(title: Text(I18n.of(sheetContext).no_more));
    }
    return ListTile(
      title: Text(
        series.title ?? series.contentOrder,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      enabled: series.viewable,
      onTap: series.viewable
          ? () {
              Navigator.of(sheetContext).pop();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _replaceWithSeriesNovel(series);
              });
            }
          : null,
    );
  }

  void _export() async {
    if (_novelStore.novelTextResponse == null) return;
    if (Platform.isAndroid) {
      // final path = await getExternalStorageDirectory();
      // if (path == null) return;
      // final dirPath = Path.join(path.path, "novel_export");
      // final dir = Directory(dirPath);
      // if (!dir.existsSync()) {
      //   dir.createSync(recursive: true);
      // }
      // final allPath = Path.join(dirPath, "All");
      // final allDir = Directory(allPath);
      // if (!allDir.existsSync()) {
      //   allDir.createSync(recursive: true);
      // }
      // final novelDirPath =
      //     Path.join(dirPath, _novelStore.novel!.title.trim().toLegal());
      // final novelDir = Directory(novelDirPath);
      // if (!novelDir.existsSync()) {
      //   novelDir.createSync(recursive: true);
      // }
      // final fileInAllPath = Path.join(
      //     allPath, "${_novelStore.novel!.title.trim().toLegal()}.txt");
      // final filePath = Path.join(novelDirPath, "${_novelStore.novel!.id}.txt");
      // final resultFile = File(filePath);
      // final data = _novelStore.novelTextResponse!.text;
      // resultFile.writeAsStringSync(data);
      // File(fileInAllPath).writeAsStringSync(data);
      // BotToast.showText(text: "export ${filePath}");
      final data = _novelStore.novelTextResponse!.text;
      final uri = await SAFPlugin.createFile(
        "${_novelStore.novel!.title.trim().toLegal()}.txt",
        "application/txt",
      );
      if (uri == null) return;
      await SAFPlugin.writeUri(uri, utf8.encode(data));
      BotToast.showText(text: "export success");
    } else if (Platform.isIOS) {
      final path = await getApplicationDocumentsDirectory();
      final dirPath = Path.join(path.path, "novel_export");
      final dir = Directory(dirPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final allPath = Path.join(dirPath, "All");
      final allDir = Directory(allPath);
      if (!allDir.existsSync()) {
        allDir.createSync(recursive: true);
      }
      final novelDirPath = Path.join(
        dirPath,
        _novelStore.novel!.title.trim().toLegal(),
      );
      final novelDir = Directory(novelDirPath);
      if (!novelDir.existsSync()) {
        novelDir.createSync(recursive: true);
      }
      final fileInAllPath = Path.join(
        allPath,
        "${_novelStore.novel!.title.trim().toLegal()}.txt",
      );
      final filePath = Path.join(novelDirPath, "${_novelStore.novel!.id}.txt");
      final resultFile = File(filePath);
      final data = _novelStore.novelTextResponse!.text;
      resultFile.writeAsStringSync(data);
      File(fileInAllPath).writeAsStringSync(data);
      LPrinter.d("path: $filePath");
      BotToast.showText(text: "export ${filePath}");
    }
  }
}
