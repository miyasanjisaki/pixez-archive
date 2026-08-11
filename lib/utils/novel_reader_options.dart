/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 */

const double minNovelFontSize = 12;
const double maxNovelFontSize = 32;
const double defaultNovelFontSize = 16;
const double minNovelLineHeight = 1.3;
const double maxNovelLineHeight = 2.2;
const double defaultNovelLineHeight = 1.65;

double clampNovelFontSize(double value) {
  return value.clamp(minNovelFontSize, maxNovelFontSize).toDouble();
}

double clampNovelLineHeight(double value) {
  return value.clamp(minNovelLineHeight, maxNovelLineHeight).toDouble();
}

double calculateNovelReadingProgress({
  required double offset,
  required double maxScrollExtent,
}) {
  if (!offset.isFinite || !maxScrollExtent.isFinite || maxScrollExtent <= 0) {
    return 0;
  }
  return (offset / maxScrollExtent).clamp(0, 1).toDouble();
}
