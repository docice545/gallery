import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/editor_geometry.dart';

void main() {
  void expectPoint(Offset actual, Offset expected) {
    expect(actual.dx, closeTo(expected.dx, 1e-9));
    expect(actual.dy, closeTo(expected.dy, 1e-9));
  }

  test('source-space crop, reflection, quarter-turn and fine rotation apply in order', () {
    final geometry = EditorGeometry(
      sourceRect: const Rect.fromLTWH(10, 20, 100, 80),
      rotationDegrees: 90,
      flipHorizontal: true,
      straightenDegrees: 10,
    );
    expect(geometry.outputSize, const Size(80, 100));
    expectPoint(geometry.sourceToOutput(const Offset(60, 60)), const Offset(40, 50));
    // Relative (20, -20) reflects to (-20, -20), then turns to (20, -20).
    final sine = math.sin(10 * math.pi / 180);
    final cosine = math.cos(10 * math.pi / 180);
    expectPoint(
      geometry.sourceToOutput(const Offset(80, 40)),
      Offset(40 + geometry.coverScale * 20 * (cosine + sine), 50 + geometry.coverScale * 20 * (sine - cosine)),
    );
    expectPoint(geometry.outputToSource(geometry.sourceToOutput(const Offset(80, 40))), const Offset(80, 40));
  });

  for (final size in [const Size(48, 32), const Size(32, 48), const Size(400, 20)]) {
    for (final rotation in [0, 90, 180, 270]) {
      for (final angle in [-15.0, -7.0, 0.0, 7.0, 15.0]) {
        test('fixed output frame is covered: source=$size rotation=$rotation straighten=$angle', () {
          final crop = Rect.fromLTWH(11, 17, size.width, size.height);
          final geometry = EditorGeometry(
            sourceRect: crop,
            rotationDegrees: rotation,
            flipHorizontal: true,
            flipVertical: true,
            straightenDegrees: angle,
          );
          final output = Offset.zero & geometry.outputSize;
          var nearestEdge = double.infinity;
          for (final point in [output.topLeft, output.topRight, output.bottomLeft, output.bottomRight]) {
            final source = geometry.outputToSource(point);
            final margins = [
              source.dx - crop.left,
              crop.right - source.dx,
              source.dy - crop.top,
              crop.bottom - source.dy,
            ];
            expect(margins.every((margin) => margin >= -1e-9), isTrue);
            nearestEdge = math.min(nearestEdge, margins.reduce(math.min));
            expectPoint(geometry.sourceToOutput(source), point);
          }
          // The cover zoom is minimal: at least one corner touches a crop edge.
          expect(nearestEdge, closeTo(0, 1e-9));
        });
      }
    }
  }

  test('quarter-turn normalization and zero-angle geometry preserve the legacy transform', () {
    final geometry = EditorGeometry(
      sourceRect: const Rect.fromLTWH(16, 0, 48, 32),
      rotationDegrees: -450,
      flipVertical: true,
    );
    expect(geometry.rotationDegrees, 270);
    expect(geometry.coverScale, 1);
    expect(geometry.outputSize, const Size(32, 48));
    expectPoint(geometry.sourceToOutput(const Offset(16, 0)), const Offset(32, 48));
    expectPoint(geometry.sourceToOutput(const Offset(64, 32)), Offset.zero);
  });

  test('geometry scales with the preview and exposes independent transform copies', () {
    final geometry = EditorGeometry(
      sourceRect: const Rect.fromLTWH(10, 20, 100, 80),
      rotationDegrees: 270,
      straightenDegrees: -9,
    );
    final preview = EditorGeometry(
      sourceRect: const Rect.fromLTWH(20, 40, 200, 160),
      rotationDegrees: 270,
      straightenDegrees: -9,
    );
    expectPoint(preview.sourceToOutput(const Offset(60, 100)), geometry.sourceToOutput(const Offset(30, 50)) * 2);
    final expected = geometry.sourceToOutput(const Offset(30, 50));
    geometry.sourceToOutputTransform.setIdentity();
    geometry.outputToSourceTransform.setIdentity();
    expectPoint(geometry.sourceToOutput(const Offset(30, 50)), expected);
    expectPoint(geometry.outputToSource(expected), const Offset(30, 50));
  });

  test('invalid inputs fail and finite fine angles clamp to the supported bounds', () {
    EditorGeometry create({Rect crop = const Rect.fromLTWH(0, 0, 80, 60), int rotation = 0, double angle = 0}) =>
        EditorGeometry(sourceRect: crop, rotationDegrees: rotation, straightenDegrees: angle);
    expect(() => create(crop: Rect.zero), throwsArgumentError);
    expect(() => create(crop: const Rect.fromLTWH(0, 0, -10, 10)), throwsArgumentError);
    expect(() => create(crop: const Rect.fromLTWH(double.nan, 0, 80, 60)), throwsArgumentError);
    expect(() => create(rotation: 45), throwsArgumentError);
    expect(() => create(angle: double.nan), throwsArgumentError);
    expect(() => create(angle: double.infinity), throwsArgumentError);
    expect(create(angle: 100).straightenDegrees, 15);
    expect(create(angle: -100).straightenDegrees, -15);
  });
}
