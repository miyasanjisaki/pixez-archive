/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 */

import 'package:flutter/material.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/models/novel_recom_response.dart';
import 'package:pixez/page/novel/component/novel_bookmark_button.dart';
import 'package:pixez/utils/novel_result_options.dart';

class NovelCard extends StatelessWidget {
  final Novel novel;
  final VoidCallback onTap;
  final NovelResultSort resultSort;

  const NovelCard({
    super.key,
    required this.novel,
    required this.onTap,
    this.resultSort = NovelResultSort.apiOrder,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: '${novel.title}, ${novel.user.name}',
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        elevation: 0,
        color: colorScheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 80,
                    height: 112,
                    child: PixivImage(
                      novel.imageUrls.medium,
                      width: 80,
                      height: 112,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 112),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          novel.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          novel.user.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.secondary,
                          ),
                        ),
                        const SizedBox(height: 5),
                        if (novel.tags.isNotEmpty || novel.NovelAIType == 2)
                          Text(
                            [
                              if (novel.NovelAIType == 2)
                                I18n.of(context).ai_generated,
                              ...novel.tags
                                  .take(2)
                                  .map((tag) => '#${tag.name}'),
                            ].join('  '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _NovelMetric(
                              icon: Icons.bookmark_outline,
                              value: _compactCount(novel.totalBookmarks),
                              tooltip: I18n.of(context).novel_bookmarks,
                              selected:
                                  resultSort == NovelResultSort.bookmarksDesc,
                            ),
                            _NovelMetric(
                              icon: Icons.visibility_outlined,
                              value: _compactCount(novel.totalView),
                              tooltip: I18n.of(context).novel_views,
                              selected: resultSort == NovelResultSort.viewsDesc,
                            ),
                            _NovelMetric(
                              icon: Icons.article_outlined,
                              value: _compactCount(novel.textLength),
                              tooltip: I18n.of(context).text,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                SizedBox(
                  width: 48,
                  height: 48,
                  child: NovelBookmarkButton(novel: novel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NovelMetric extends StatelessWidget {
  final IconData icon;
  final String value;
  final String tooltip;
  final bool selected;

  const _NovelMetric({
    required this.icon,
    required this.value,
    required this.tooltip,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.secondaryContainer
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 4),
            Text(
              value,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: foreground,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _compactCount(int value) {
  if (value < 1000) return '$value';
  if (value < 1000000) return _compactUnit(value / 1000, 'K');
  if (value < 1000000000) return _compactUnit(value / 1000000, 'M');
  return _compactUnit(value / 1000000000, 'B');
}

String _compactUnit(double value, String unit) {
  final digits = value >= 100 || value == value.roundToDouble() ? 0 : 1;
  return '${value.toStringAsFixed(digits)}$unit';
}
