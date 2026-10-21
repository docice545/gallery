import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:immich_mobile/constants/filters.dart';

/// The same affine, source-pixel pipeline is used for preview, thumbnails and export.
class ColorAdjustment {
  static const keys = {
    'brightness',
    'contrast',
    'saturation',
    'exposure',
    'temperature',
    'shadows',
    'highlights',
    'hue',
  };

  /// Compose outer(inner(rgba)), including translation and alpha, without clamping
  /// intermediate pixels. Flutter's ColorFilter has no compose constructor.
  static List<double> compose(List<double> outer, List<double> inner) => List.generate(20, (index) {
    final row = index ~/ 5;
    final column = index % 5;
    var value = column == 4 ? outer[row * 5 + 4] : 0.0;
    for (var k = 0; k < 4; k++) {
      value += outer[row * 5 + k] * inner[k * 5 + column];
    }
    return value;
  });

  static List<double> buildMatrix(Map<String, double> adjustments) {
    var result = List<double>.of(identityMatrix);
    double value(String key) {
      final v = adjustments[key] ?? 0;
      if (!v.isFinite) {
        throw ArgumentError.value(v, key, 'Must be finite');
      }
      return v;
    }

    void apply(List<double> matrix) => result = compose(matrix, result);
    List<double> diagonal(double r, double g, double b, [double offset = 0]) => [
      r,
      0,
      0,
      0,
      offset,
      0,
      g,
      0,
      0,
      offset,
      0,
      0,
      b,
      0,
      offset,
      0,
      0,
      0,
      1,
      0,
    ];

    apply(diagonal(1, 1, 1, value('brightness').clamp(-1.0, 1.0) * 255));
    final contrast = (1 + value('contrast')).clamp(0.0, 3.0);
    apply(diagonal(contrast, contrast, contrast, 128 * (1 - contrast)));
    final saturation = (1 + value('saturation')).clamp(0.0, 2.0);
    const luminance = [.213, .715, .072];
    apply(
      List.generate(20, (index) {
        final row = index ~/ 5;
        final col = index % 5;
        if (row == 3) {
          return col == 3 ? 1.0 : 0.0;
        }
        if (col > 2) {
          return 0.0;
        }
        return (1 - saturation) * luminance[col] + (row == col ? saturation : 0);
      }),
    );
    final exposure = math.pow(2, value('exposure').clamp(-1.0, 1.0)).toDouble();
    apply(diagonal(exposure, exposure, exposure));
    final temperature = value('temperature').clamp(-1.0, 1.0) * .1;
    apply(diagonal(1 + temperature, 1, 1 - temperature));
    // A bounded affine lift keeps white fixed; highlights keep black fixed.
    final shadows = value('shadows').clamp(-1.0, 1.0) * 50;
    apply(diagonal(1 - shadows / 255, 1 - shadows / 255, 1 - shadows / 255, shadows));
    final highlights = 1 + value('highlights').clamp(-1.0, 1.0) * 50 / 255;
    apply(diagonal(highlights, highlights, highlights));
    final hue = value('hue').clamp(-1.0, 1.0) * math.pi;
    final c = math.cos(hue);
    final s = math.sin(hue);
    const r = .213;
    const g = .715;
    const b = .072;
    apply([
      r + c * (1 - r) - s * r,
      g - c * g - s * g,
      b - c * b + s * (1 - b),
      0,
      0,
      r - c * r + s * .143,
      g + c * (1 - g) + s * .140,
      b - c * b - s * .283,
      0,
      0,
      r - c * r - s * (1 - r),
      g - c * g + s * g,
      b + c * (1 - b) + s * b,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]);
    return result;
  }

  static List<double> combinedMatrix(Map<String, double> adjustments, int filter, double intensity) =>
      compose(filterMatrixAtIntensity(filter, intensity), buildMatrix(adjustments));

  static ColorFilter combinedFilter(Map<String, double> adjustments, int filter, double intensity) =>
      ColorFilter.matrix(combinedMatrix(adjustments, filter, intensity));

  static ColorFilter? buildFilter(Map<String, double> adjustments) =>
      adjustments.isEmpty ? null : ColorFilter.matrix(buildMatrix(adjustments));
}
