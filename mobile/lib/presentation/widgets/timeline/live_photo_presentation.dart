import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// The native player aspect-fits inside the still image's canvas. Only reveal
/// its surface when that preserves the crop and has enough actual source pixels.
/// No spatial registration exists for pairs with different fields of view.
bool canPresentTimelineMotion({required Size imageSize, required Size videoSize, required Size requiredSize}) {
  bool valid(Size size) => size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0;
  if (!valid(imageSize) || !valid(videoSize) || !valid(requiredSize)) {
    return false;
  }
  // Accommodate integer codec dimension rounding, not a different camera crop.
  final aspectTolerance = math.max(1 / imageSize.height, 1 / videoSize.height);
  // Full-source scale arithmetic can put an exact integer target just above it.
  const pixelTolerance = 1e-9;
  return (imageSize.aspectRatio - videoSize.aspectRatio).abs() <= aspectTolerance &&
      videoSize.width + pixelTolerance >= requiredSize.width &&
      videoSize.height + pixelTolerance >= requiredSize.height;
}
