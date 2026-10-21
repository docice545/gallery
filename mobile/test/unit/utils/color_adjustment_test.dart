import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/color_adjustment.dart';

void main() {
  group('ColorAdjustment', () {
    test('buildMatrix returns identity for empty adjustments', () {
      final matrix = ColorAdjustment.buildMatrix({});
      
      // Identity matrix
      expect(matrix[0], 1.0);
      expect(matrix[6], 1.0);
      expect(matrix[12], 1.0);
      expect(matrix[18], 1.0);
      expect(matrix[4], 0.0);
      expect(matrix[9], 0.0);
      expect(matrix[14], 0.0);
    });

    test('buildFilter returns null for empty adjustments', () {
      final filter = ColorAdjustment.buildFilter({});
      expect(filter, isNull);
    });

    test('brightness adjustment modifies matrix correctly', () {
      final matrix = ColorAdjustment.buildMatrix({'brightness': 0.5});
      
      // Brightness 0.5 should add 127.5 to each channel
      expect(matrix[4], closeTo(127.5, 0.1));
      expect(matrix[9], closeTo(127.5, 0.1));
      expect(matrix[14], closeTo(127.5, 0.1));
    });

    test('negative brightness adjustment modifies matrix correctly', () {
      final matrix = ColorAdjustment.buildMatrix({'brightness': -0.5});
      
      // Brightness -0.5 should subtract 127.5 from each channel
      expect(matrix[4], closeTo(-127.5, 0.1));
      expect(matrix[9], closeTo(-127.5, 0.1));
      expect(matrix[14], closeTo(-127.5, 0.1));
    });

    test('contrast adjustment modifies matrix correctly', () {
      final matrix = ColorAdjustment.buildMatrix({'contrast': 0.5});
      
      // Contrast 0.5 -> c = 1.5
      // Diagonal elements should be multiplied by 1.5
      expect(matrix[0], closeTo(1.5, 0.1));
      expect(matrix[6], closeTo(1.5, 0.1));
      expect(matrix[12], closeTo(1.5, 0.1));
      // Offsets should be adjusted
      expect(matrix[4], closeTo(128 * (1 - 1.5), 0.1));
    });

    test('saturation adjustment modifies matrix correctly', () {
      final matrix = ColorAdjustment.buildMatrix({'saturation': 0.5});
      
      // Saturation 0.5 -> s = 1.5 (clamped to 2.0 max)
      // The matrix should mix with luminance weights
      expect(matrix[0], closeTo(1.3935, 0.0001));
      expect(matrix[1], closeTo(-0.3575, 0.0001));
      expect(matrix[2], closeTo(-0.036, 0.0001));
    });

    test('exposure adjustment modifies matrix correctly', () {
      final matrix = ColorAdjustment.buildMatrix({'exposure': 1.0});
      
      // Exposure 1.0 -> 2^1 = 2
      expect(matrix[0], closeTo(2.0, 0.1));
      expect(matrix[6], closeTo(2.0, 0.1));
      expect(matrix[12], closeTo(2.0, 0.1));
    });

    test('temperature adjustment modifies matrix correctly', () {
      final matrix = ColorAdjustment.buildMatrix({'temperature': 1.0});
      
      // Temperature 1.0 -> t = 0.1
      // Red should increase, blue should decrease
      expect(matrix[0], closeTo(1.1, 0.1));
      expect(matrix[12], closeTo(0.9, 0.1));
    });

    test('shadows adjustment modifies matrix correctly', () {
      final matrix = ColorAdjustment.buildMatrix({'shadows': 0.5});
      
      // Shadows 0.5 -> s = 25
      expect(matrix[4], closeTo(25.0, 0.1));
      expect(matrix[9], closeTo(25.0, 0.1));
      expect(matrix[14], closeTo(25.0, 0.1));
    });

    test('highlights adjustment modifies matrix correctly', () {
      final matrix = ColorAdjustment.buildMatrix({'highlights': 0.5});
      
      // Highlights 0.5 -> h = 25
      expect(matrix[0], closeTo(1 + 25/255, 0.1));
      expect(matrix[6], closeTo(1 + 25/255, 0.1));
      expect(matrix[12], closeTo(1 + 25/255, 0.1));
    });

    test('multiple adjustments combine correctly', () {
      final matrix = ColorAdjustment.buildMatrix({
        'brightness': 0.2,
        'contrast': 0.3,
        'saturation': -0.5,
      });
      
      // All should be applied
      expect(matrix[0], isNot(1.0));
      expect(matrix[4], isNot(0.0));
    });

    test('clamping works for extreme values', () {
      // Contrast should be clamped to [0, 3]
      final matrix1 = ColorAdjustment.buildMatrix({'contrast': 10.0});
      expect(matrix1[0], closeTo(3.0, 0.1));
      
      // Saturation should be clamped to [0, 2]
      final matrix2 = ColorAdjustment.buildMatrix({'saturation': 10.0});
      // Should not crash and produce valid matrix
      expect(matrix2.length, 20);
    });
  });
}
