import 'dart:math' as math;

import 'package:flutter/painting.dart';

class ThumbnailFraming {
  const ThumbnailFraming({required this.fit, required this.alignment});

  final BoxFit fit;
  final Alignment alignment;
}

/// Frames the upright image using face bounds normalized to its full size.
///
/// Every valid face remains inside the visible source rectangle. When their
/// union cannot fit a cover crop, the full image is shown instead.
ThumbnailFraming faceAwareThumbnailFraming({
  required Size imageSize,
  required Size viewportSize,
  required List<Rect> faces,
  BoxFit fit = BoxFit.cover,
}) {
  final fallback = ThumbnailFraming(fit: fit, alignment: Alignment.center);
  if (fit != BoxFit.cover || !_isValidSize(imageSize) || !_isValidSize(viewportSize)) {
    return fallback;
  }

  Rect? faceBounds;
  for (final face in faces) {
    if (!face.left.isFinite ||
        !face.top.isFinite ||
        !face.right.isFinite ||
        !face.bottom.isFinite ||
        face.width <= 0 ||
        face.height <= 0 ||
        face.right <= 0 ||
        face.bottom <= 0 ||
        face.left >= 1 ||
        face.top >= 1) {
      continue;
    }

    final clipped = Rect.fromLTRB(
      face.left.clamp(0.0, 1.0),
      face.top.clamp(0.0, 1.0),
      face.right.clamp(0.0, 1.0),
      face.bottom.clamp(0.0, 1.0),
    );
    faceBounds = faceBounds?.expandToInclude(clipped) ?? clipped;
  }
  if (faceBounds == null) {
    return fallback;
  }

  final source = applyBoxFit(fit, imageSize, viewportSize).source;
  if (!_isValidSize(source)) {
    return fallback;
  }
  final cropWidth = (source.width / imageSize.width).clamp(0.0, 1.0);
  final cropHeight = (source.height / imageSize.height).clamp(0.0, 1.0);
  if (faceBounds.width > cropWidth || faceBounds.height > cropHeight) {
    return const ThumbnailFraming(fit: BoxFit.contain, alignment: Alignment.center);
  }

  final horizontalAlignment = _axisAlignment(faceBounds.left, faceBounds.right, cropWidth);
  // Keep the faces slightly above center when the available crop permits it.
  final verticalAlignment = _axisAlignment(faceBounds.top, faceBounds.bottom, cropHeight, focalFraction: 0.42);
  if (horizontalAlignment == null || verticalAlignment == null) {
    return const ThumbnailFraming(fit: BoxFit.contain, alignment: Alignment.center);
  }
  return ThumbnailFraming(fit: fit, alignment: Alignment(horizontalAlignment, verticalAlignment));
}

bool _isValidSize(Size size) => size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0;

double? _axisAlignment(double first, double last, double extent, {double focalFraction = 0.5}) {
  final overflow = 1 - extent;
  if (overflow <= 0) {
    return 0;
  }

  // These limits keep both edges of the entire face union in the crop window.
  final minOffset = math.max(0.0, last - extent);
  final maxOffset = math.min(first, overflow);
  if (minOffset > maxOffset) {
    // An exactly fitting union can leave an empty interval after rounding.
    return null;
  }
  final desiredOffset = (first + last) / 2 - extent * focalFraction;
  final offset = desiredOffset.clamp(minOffset, maxOffset);
  return (2 * offset / overflow - 1).clamp(-1.0, 1.0);
}
