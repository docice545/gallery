import 'package:flutter/painting.dart';

/// Validate presentation geometry, not pixel parity with the original still.
/// Samsung/Apple paired videos commonly have fewer pixels and a different camera
/// crop. Rejecting those consumes the viewport's one-shot without ever playing.
/// The sharp still remains the baseline before and after the short motion pass.
bool canPresentTimelineMotion({required Size imageSize, required Size videoSize, required Size requiredSize}) {
  bool valid(Size size) => size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0;
  return valid(imageSize) && valid(videoSize) && valid(requiredSize);
}

/// Give the aspect-fitting native surface its own source aspect, then cover the
/// existing still canvas. Bounds stay in logical tile pixels, not original pixels.
Size timelineMotionCanvasSize({required Size viewportSize, required Size videoSize}) {
  final aspect = videoSize.aspectRatio;
  return aspect > viewportSize.aspectRatio
      ? Size(viewportSize.height * aspect, viewportSize.height)
      : Size(viewportSize.width, viewportSize.width / aspect);
}
