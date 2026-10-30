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
  bool preserveEdgeContent = false,
}) {
  final fallback = ThumbnailFraming(fit: fit, alignment: Alignment.center);
  if (fit != BoxFit.cover || !_isValidSize(imageSize) || !_isValidSize(viewportSize)) {
    return fallback;
  }

  // Screenshots, documents, receipts and conversations often put their only
  // meaningful pixels at an edge. A centered cover crop turns those assets
  // into a white/empty tile even though the source thumbnail is valid. Keep
  // the entire source for this explicit content class; ordinary photographs
  // retain the existing cover behavior.
  if (preserveEdgeContent) {
    return const ThumbnailFraming(fit: BoxFit.contain, alignment: Alignment.center);
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

/// Identifies assets whose framing must preserve the full source in a grid.
/// The name signal covers Android/iOS screenshot and document exports; the
/// aspect signal catches unnamed phone captures without changing normal 4:3 or
/// 3:2 photographs.
bool shouldPreserveEdgeContent(String name, {int? width, int? height}) {
  final normalized = name.toLowerCase().replaceAll(RegExp(r'[_-]+'), ' ');
  final edgeContentName = RegExp(
    r'\b(screen ?shot|screen capture|screenrecord|document|scan|receipt|chat|conversation|whatsapp|telegram|signal)\b',
  );
  if (edgeContentName.hasMatch(normalized)) {
    return true;
  }

  if (width == null || height == null || width <= 0 || height <= 0) {
    return false;
  }
  // Keep the aspect-ratio fallback for display captures that do not carry a
  // descriptive filename. Camera photos in the same portrait aspect must
  // retain the normal cover framing; the test fixture and most camera assets
  // use JPEG while screen exports use PNG/WebP.
  final displayCaptureFormat = normalized.endsWith('.png') || normalized.endsWith('.webp');
  if (!displayCaptureFormat) {
    return false;
  }
  final longEdge = math.max(width, height);
  final aspect = longEdge / math.min(width, height);
  // Unnamed phone captures are commonly exported at the display resolution
  // (rather than the multi-megapixel dimensions of ordinary camera photos).
  // Keep the threshold narrow so a normal portrait photo still uses cover.
  return longEdge <= 3000 && aspect >= 1.65 && aspect <= 2.25;
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
