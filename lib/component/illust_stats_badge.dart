/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 */

import 'package:flutter/material.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/utils/illust_card_stats.dart';

class IllustStatsBadge extends StatelessWidget {
  const IllustStatsBadge({
    super.key,
    required this.bookmarks,
    required this.views,
  });

  final int? bookmarks;
  final int? views;

  @override
  Widget build(BuildContext context) {
    if (!hasCompleteIllustCardStats(bookmarks: bookmarks, views: views)) {
      return const SizedBox.shrink();
    }

    final bookmarkCount = bookmarks!;
    final viewCount = views!;
    return Semantics(
      label:
          '${I18n.of(context).total_bookmark}: $bookmarkCount, '
          '${I18n.of(context).total_view}: $viewCount',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bookmark, size: 13, color: Colors.white),
            const SizedBox(width: 3),
            Text(
              formatIllustCardStatCount(bookmarkCount),
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
            const SizedBox(width: 7),
            const Icon(Icons.visibility, size: 13, color: Colors.white),
            const SizedBox(width: 3),
            Text(
              formatIllustCardStatCount(viewCount),
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
