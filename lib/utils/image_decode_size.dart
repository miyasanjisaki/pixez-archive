/// Converts a logical layout extent into a bounded physical decode extent.
int? calculateImageCacheDimension(
  double? logicalPixels,
  double devicePixelRatio, {
  int maximumDimension = 4096,
}) {
  if (logicalPixels == null ||
      !logicalPixels.isFinite ||
      logicalPixels <= 0 ||
      !devicePixelRatio.isFinite ||
      devicePixelRatio <= 0 ||
      maximumDimension <= 0) {
    return null;
  }

  final physicalPixels = (logicalPixels * devicePixelRatio).ceil();
  return physicalPixels.clamp(1, maximumDimension).toInt();
}
