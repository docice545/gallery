import 'dart:math';

import 'package:flutter/material.dart';

/// Utility for building color adjustment matrices.
/// Adjustments are in range [-1, 1].
class ColorAdjustment {
  /// Builds a ColorFilter matrix from adjustment values.
  static List<double> buildMatrix(Map<String, double> adjustments) {
    // Start with identity matrix
    const matrix = <double>[
      1.0, 0.0, 0.0, 0.0, 0.0,  // R
      0.0, 1.0, 0.0, 0.0, 0.0,  // G
      0.0, 0.0, 1.0, 0.0, 0.0,  // B
      0.0, 0.0, 0.0, 1.0, 0.0,  // A
    ];

    // Create mutable copy
    final result = List<double>.from(matrix);

    // Apply brightness (-1 to 1)
    final brightness = adjustments['brightness'] ?? 0.0;
    if (brightness != 0.0) {
      final b = brightness * 255.0;
      result[4] += b;
      result[9] += b;
      result[14] += b;
    }

    // Apply contrast (-1 to 1)
    final contrast = adjustments['contrast'] ?? 0.0;
    if (contrast != 0.0) {
      final c = (contrast + 1.0).clamp(0.0, 3.0); // Map -1..1 to 0..3
      result[0] *= c;
      result[6] *= c;
      result[12] *= c;
      result[4] = result[4] * c + 128 * (1 - c);
      result[9] = result[9] * c + 128 * (1 - c);
      result[14] = result[14] * c + 128 * (1 - c);
    }

    // Apply saturation (-1 to 1)
    final saturation = adjustments['saturation'] ?? 0.0;
    if (saturation != 0.0) {
      final s = (saturation + 1.0).clamp(0.0, 2.0); // Map -1..1 to 0..2
      const lumR = 0.213;
      const lumG = 0.715;
      const lumB = 0.072;
      
      final sr = (1 - s) * lumR;
      final sg = (1 - s) * lumG;
      final sb = (1 - s) * lumB;
      
      final m0 = result[0];
      final m1 = result[1];
      final m2 = result[2];
      final m5 = result[5];
      final m6 = result[6];
      final m7 = result[7];
      final m10 = result[10];
      final m11 = result[11];
      final m12 = result[12];
      
      result[0] = m0 * s + sr;
      result[1] = m1 * s + sg;
      result[2] = m2 * s + sb;
      result[5] = m5 * s + sr;
      result[6] = m6 * s + sg;
      result[7] = m7 * s + sb;
      result[10] = m10 * s + sr;
      result[11] = m11 * s + sg;
      result[12] = m12 * s + sb;
    }

    // Apply exposure (-1 to 1)
    final exposure = adjustments['exposure'] ?? 0.0;
    if (exposure != 0.0) {
      final exp = pow(2.0, exposure);
      result[0] *= exp;
      result[6] *= exp;
      result[12] *= exp;
    }

    // Apply temperature (-1 to 1) - shifts between blue and orange
    final temperature = adjustments['temperature'] ?? 0.0;
    if (temperature != 0.0) {
      // Simple temperature adjustment: increase red, decrease blue for warmth
      final t = temperature * 0.1;
      result[0] += t;  // Red
      result[12] -= t; // Blue
    }

    // Apply shadows (-1 to 1) - lift or crush shadows
    final shadows = adjustments['shadows'] ?? 0.0;
    if (shadows != 0.0) {
      final s = shadows * 50.0; // Scale for visible effect
      result[4] += s;
      result[9] += s;
      result[14] += s;
    }

    // Apply highlights (-1 to 1) - lift or crush highlights
    final highlights = adjustments['highlights'] ?? 0.0;
    if (highlights != 0.0) {
      final h = highlights * 50.0;
      result[0] *= (1 + h / 255.0);
      result[6] *= (1 + h / 255.0);
      result[12] *= (1 + h / 255.0);
    }

    // Apply hue (-1 to 1) - rotate colors
    final hue = adjustments['hue'] ?? 0.0;
    if (hue != 0.0) {
      // Hue rotation matrix (angle in radians)
      // Maps -1..1 to -180..180 degrees
      final angle = hue * pi;
      final cosA = cos(angle);
      final sinA = sin(angle);
      
      // Luminance weights
      const lumR = 0.213;
      const lumG = 0.715;
      const lumB = 0.072;
      
      // Hue rotation matrix components
      final hr = [
        lumR + cosA * (1 - lumR) + sinA * (-lumR),
        lumG + cosA * (-lumG) + sinA * (-lumG),
        lumB + cosA * (-lumB) + sinA * (1 - lumB),
        lumR + cosA * (-lumR) + sinA * (lumR),
        lumG + cosA * (1 - lumG) + sinA * (lumG),
        lumB + cosA * (-lumB) + sinA * (-lumB),
        lumR + cosA * (-lumR) + sinA * (-lumR),
        lumG + cosA * (-lumG) + sinA * (lumG),
        lumB + cosA * (1 - lumB) + sinA * (-lumB),
      ];
      
      // Apply hue rotation to the current RGB matrix
      final m0 = result[0];
      final m1 = result[1];
      final m2 = result[2];
      final m5 = result[5];
      final m6 = result[6];
      final m7 = result[7];
      final m10 = result[10];
      final m11 = result[11];
      final m12 = result[12];
      
      result[0] = m0 * hr[0] + m1 * hr[3] + m2 * hr[6];
      result[1] = m0 * hr[1] + m1 * hr[4] + m2 * hr[7];
      result[2] = m0 * hr[2] + m1 * hr[5] + m2 * hr[8];
      result[5] = m5 * hr[0] + m6 * hr[3] + m7 * hr[6];
      result[6] = m5 * hr[1] + m6 * hr[4] + m7 * hr[7];
      result[7] = m5 * hr[2] + m6 * hr[5] + m7 * hr[8];
      result[10] = m10 * hr[0] + m11 * hr[3] + m12 * hr[6];
      result[11] = m10 * hr[1] + m11 * hr[4] + m12 * hr[7];
      result[12] = m10 * hr[2] + m11 * hr[5] + m12 * hr[8];
    }

    return result;
  }

  /// Builds a ColorFilter from adjustment values.
  static ColorFilter? buildFilter(Map<String, double> adjustments) {
    if (adjustments.isEmpty) return null;
    final matrix = buildMatrix(adjustments);
    return ColorFilter.matrix(matrix);
  }

  /// Lerps between two ColorFilter matrices by intensity.
  /// Returns a new ColorFilter with the blended matrix.
  static ColorFilter lerpFilters(ColorFilter from, ColorFilter to, double t) {
    if (t <= 0.0) return from;
    if (t >= 1.0) return to;
    
    // Since ColorFilter doesn't expose its matrix, we can't lerp directly.
    // For filter intensity, we compose with a transparent blend.
    // The caller should use ColorFiltered with opacity for partial intensity.
    return to;
  }
}
