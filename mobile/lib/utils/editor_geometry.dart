import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Geometry shared by the full-resolution export, preview and pointer mapping.
/// [sourceRect] is the selected crop in the source image's coordinate system.
/// Fine rotation follows the quarter-turn/flip and keeps a fixed output frame,
/// enlarging the selected crop just enough to avoid empty corners.
class EditorGeometry {
  factory EditorGeometry({
    required Rect sourceRect,
    required int rotationDegrees,
    bool flipHorizontal = false,
    bool flipVertical = false,
    double straightenDegrees = 0,
  }) {
    if (![sourceRect.left, sourceRect.top, sourceRect.right, sourceRect.bottom].every((value) => value.isFinite) ||
        sourceRect.isEmpty ||
        !sourceRect.width.isFinite ||
        !sourceRect.height.isFinite) {
      throw ArgumentError.value(sourceRect, 'sourceRect', 'Crop must be finite with positive width and height');
    }
    final rotation = rotationDegrees % 360;
    if (rotation % 90 != 0) {
      throw ArgumentError.value(rotationDegrees, 'rotationDegrees', 'Only quarter-turn rotations are supported');
    }
    final straighten = clampStraightenDegrees(straightenDegrees);
    final sideways = rotation == 90 || rotation == 270;
    final outputSize = sideways ? Size(sourceRect.height, sourceRect.width) : Size(sourceRect.width, sourceRect.height);
    final radians = straighten * math.pi / 180;
    final cosine = math.cos(radians).abs();
    final sine = math.sin(radians).abs();
    final coverScale = math.max(
      (outputSize.width * cosine + outputSize.height * sine) / outputSize.width,
      (outputSize.width * sine + outputSize.height * cosine) / outputSize.height,
    );
    final transform = Matrix4.identity()..translateByDouble(outputSize.width / 2, outputSize.height / 2, 0, 1);
    if (straighten != 0) {
      transform
        ..rotateZ(radians)
        ..scaleByDouble(coverScale, coverScale, 1, 1);
    }
    transform
      ..rotateZ(rotation * math.pi / 180)
      ..scaleByDouble(flipHorizontal ? -1.0 : 1.0, flipVertical ? -1.0 : 1.0, 1, 1)
      ..translateByDouble(-sourceRect.center.dx, -sourceRect.center.dy, 0, 1);
    return EditorGeometry._(
      sourceRect,
      rotation,
      straighten,
      outputSize,
      coverScale,
      transform,
      Matrix4.inverted(transform),
    );
  }

  EditorGeometry._(
    this.sourceRect,
    this.rotationDegrees,
    this.straightenDegrees,
    this.outputSize,
    this.coverScale,
    this._sourceToOutputTransform,
    this._outputToSourceTransform,
  );

  static const maxStraightenDegrees = 15.0;

  static double clampStraightenDegrees(double degrees) {
    if (!degrees.isFinite) {
      throw ArgumentError.value(degrees, 'straightenDegrees', 'Angle must be finite');
    }
    return degrees.clamp(-maxStraightenDegrees, maxStraightenDegrees);
  }

  final Rect sourceRect;
  final int rotationDegrees;
  final double straightenDegrees;
  final Size outputSize;
  final double coverScale;
  final Matrix4 _sourceToOutputTransform;
  final Matrix4 _outputToSourceTransform;

  // Return copies so a Transform caller cannot mutate another consumer's matrix.
  Matrix4 get sourceToOutputTransform => _sourceToOutputTransform.clone();
  Matrix4 get outputToSourceTransform => _outputToSourceTransform.clone();

  Offset sourceToOutput(Offset point) => MatrixUtils.transformPoint(_sourceToOutputTransform, point);
  Offset outputToSource(Offset point) => MatrixUtils.transformPoint(_outputToSourceTransform, point);
}
