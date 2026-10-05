import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_framing.dart';
import 'package:openapi/api.dart';

class TimelineThumbnailRequest {
  const TimelineThumbnailRequest({required this.requiredSize, required this.decodeSize, required this.remoteMediaSize});

  /// Unrounded physical source dimensions needed for the tile's framing.
  ///
  /// Native image dimensions, the selected source and the decode budget bound
  /// this requirement. Use it to assess motion quality without cache bucketing.
  final Size requiredSize;

  /// Bucketed physical dimensions of the full, upright source image to decode.
  final Size decodeSize;

  /// The smallest available server source that can satisfy [decodeSize].
  final AssetMediaSize remoteMediaSize;
}

const _decodeBucket = 128.0;
const _maxDecodeEdge = 1440.0;
// The server's default thumbnail is resized to 250 pixels on its short side.
const _thumbnailShortEdge = 250.0;
const _fallbackViewport = Size.square(320);

/// Plans a bounded decode for a logical timeline tile at the current DPR.
///
/// [imageSize] is the asset's upright source size. The requested size preserves
/// its entire aspect ratio, including the parts outside a cover crop. Face
/// unions that need contain framing use the smaller contain decode instead.
TimelineThumbnailRequest buildTimelineThumbnailRequest({
  required Size viewportSize,
  required double devicePixelRatio,
  Size? imageSize,
  List<Rect> faces = const [],
  BoxFit fit = BoxFit.cover,
}) {
  final viewport = _isValidSize(viewportSize) ? viewportSize : _fallbackViewport;
  final dpr = devicePixelRatio.isFinite && devicePixelRatio > 0 ? devicePixelRatio : 1.0;
  final physicalViewport = Size(viewport.width * dpr, viewport.height * dpr);
  final source = imageSize;
  final Size requiredSize;
  final Size decodeSize;
  final AssetMediaSize remoteMediaSize;
  if (source == null || !_isValidSize(source)) {
    // No aspect metadata is available yet. Bound the physical viewport while
    // retaining its aspect ratio, including when multiplication overflows.
    final viewportLongEdge = math.max(viewport.width, viewport.height);
    final physicalLongEdge = viewportLongEdge * dpr;
    // With no source aspect ratio, a 250-square thumbnail is the conservative
    // estimate: both physical viewport axes must fit it.
    remoteMediaSize = physicalLongEdge <= _thumbnailShortEdge ? AssetMediaSize.thumbnail : AssetMediaSize.preview;
    final limit = remoteMediaSize == AssetMediaSize.thumbnail ? _thumbnailShortEdge : _maxDecodeEdge;
    requiredSize = _sizeAtLongEdge(viewport, math.min(physicalLongEdge, limit), clampToSource: false);
    final decodeLongEdge = _quantizedLongEdge(physicalLongEdge, limit);
    decodeSize = _sizeAtLongEdge(viewport, decodeLongEdge, clampToSource: false);
  } else {
    final framing = faceAwareThumbnailFraming(imageSize: source, viewportSize: viewport, faces: faces, fit: fit);
    final widthScale = physicalViewport.width / source.width;
    final heightScale = physicalViewport.height / source.height;
    final requiredScale = switch (framing.fit) {
      BoxFit.cover || BoxFit.fill => math.max(widthScale, heightScale),
      BoxFit.contain => math.min(widthScale, heightScale),
      BoxFit.fitWidth => widthScale,
      BoxFit.fitHeight => heightScale,
      BoxFit.none => 1.0,
      BoxFit.scaleDown => math.min(1.0, math.min(widthScale, heightScale)),
    };
    final nativeLongEdge = math.max(source.width, source.height);
    final nativeShortEdge = math.min(source.width, source.height);
    final boundedScale = math.min(1.0, requiredScale);
    // Select before bucketing so rounding a 200-square request to 256 does not
    // fetch a preview when the existing 250-square thumbnail is sufficient.
    remoteMediaSize = nativeShortEdge * boundedScale <= _thumbnailShortEdge
        ? AssetMediaSize.thumbnail
        : AssetMediaSize.preview;
    final sourceLongEdge = remoteMediaSize == AssetMediaSize.thumbnail
        ? nativeLongEdge * math.min(1.0, _thumbnailShortEdge / nativeShortEdge)
        : nativeLongEdge;
    final limit = math.min(sourceLongEdge, _maxDecodeEdge);
    final requiredLongEdge = nativeLongEdge * boundedScale;
    requiredSize = _sizeAtLongEdge(source, math.min(requiredLongEdge, limit));
    decodeSize = _sizeAtLongEdge(source, _quantizedLongEdge(requiredLongEdge, limit));
  }

  return TimelineThumbnailRequest(requiredSize: requiredSize, decodeSize: decodeSize, remoteMediaSize: remoteMediaSize);
}

bool _isValidSize(Size size) => size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0;

double _quantizedLongEdge(double required, double limit) {
  // Bound before ceil: a finite viewport multiplied by DPR may overflow.
  final bounded = math.min(required, limit);
  return math.min(math.max(1, (bounded / _decodeBucket).ceil()) * _decodeBucket, limit);
}

Size _sizeAtLongEdge(Size source, double longEdge, {bool clampToSource = true}) {
  final sourceLongEdge = math.max(source.width, source.height);
  // Divide first to avoid overflowing very large but finite source dimensions.
  // Extremely narrow aspects may underflow; retain a positive decode axis.
  final width = math.max(double.minPositive, source.width / sourceLongEdge * longEdge);
  final height = math.max(double.minPositive, source.height / sourceLongEdge * longEdge);
  return clampToSource ? Size(math.min(source.width, width), math.min(source.height, height)) : Size(width, height);
}
