import 'package:flutter/material.dart';

/// Filter matrices - each is a 20-element list representing a 4x5 color matrix
const List<List<double>> filterMatrices = [
  // Original (index 0) - identity
  [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
  // Vintage
  [0.8, 0.1, 0.1, 0, 20, 0.1, 0.8, 0.1, 0, 20, 0.1, 0.1, 0.8, 0, 20, 0, 0, 0, 1, 0],
  // Mood
  [1.2, 0.1, 0.1, 0, 10, 0.1, 1, 0.1, 0, 10, 0.1, 0.1, 1, 0, 10, 0, 0, 0, 1, 0],
  // Crisp
  [1.2, 0, 0, 0, 0, 0, 1.2, 0, 0, 0, 0, 0, 1.2, 0, 0, 0, 0, 0, 1, 0],
  // Cool
  [0.9, 0, 0.2, 0, 0, 0, 1, 0.1, 0, 0, 0.1, 0, 1.2, 0, 0, 0, 0, 0, 1, 0],
  // Blush
  [1.1, 0.1, 0.1, 0, 10, 0.1, 1, 0.1, 0, 10, 0.1, 0.1, 1, 0, 5, 0, 0, 0, 1, 0],
  // Sunkissed
  [1.3, 0, 0.1, 0, 15, 0, 1.1, 0.1, 0, 10, 0, 0, 0.9, 0, 5, 0, 0, 0, 1, 0],
  // Fresh
  [1.2, 0, 0, 0, 20, 0, 1.2, 0, 0, 20, 0, 0, 1.1, 0, 20, 0, 0, 0, 1, 0],
  // Classic
  [1.1, 0, -0.1, 0, 10, -0.1, 1.1, 0.1, 0, 5, 0, -0.1, 1.1, 0, 0, 0, 0, 0, 1, 0],
  // Lomo-ish
  [1.5, 0, 0.1, 0, 0, 0, 1.45, 0, 0, 0, 0.1, 0, 1.3, 0, 0, 0, 0, 0, 1, 0],
  // Nashville
  [1.2, 0.15, -0.15, 0, 15, 0.1, 1.1, 0.1, 0, 10, -0.05, 0.2, 1.25, 0, 5, 0, 0, 0, 1, 0],
  // Valencia
  [1.15, 0.1, 0.1, 0, 20, 0.1, 1.1, 0, 0, 10, 0.1, 0.1, 1.2, 0, 5, 0, 0, 0, 1, 0],
  // Clarendon
  [1.2, 0, 0, 0, 10, 0, 1.25, 0, 0, 10, 0, 0, 1.3, 0, 10, 0, 0, 0, 1, 0],
  // Moon
  [0.33, 0.33, 0.33, 0, 0, 0.33, 0.33, 0.33, 0, 0, 0.33, 0.33, 0.33, 0, 0, 0, 0, 0, 1, 0],
  // Willow
  [0.5, 0.5, 0.5, 0, 20, 0.5, 0.5, 0.5, 0, 20, 0.5, 0.5, 0.5, 0, 20, 0, 0, 0, 1, 0],
  // Kodak
  [1.3, 0.1, -0.1, 0, 10, 0, 1.25, 0.1, 0, 10, 0, -0.1, 1.1, 0, 5, 0, 0, 0, 1, 0],
  // Frost
  [0.8, 0.2, 0.1, 0, 0, 0.2, 1.1, 0.1, 0, 0, 0.1, 0.1, 1.2, 0, 10, 0, 0, 0, 1, 0],
  // Night Vision
  [0.1, 0.95, 0.2, 0, 0, 0.1, 1.5, 0.1, 0, 0, 0.2, 0.7, 0, 0, 0, 0, 0, 0, 1, 0],
  // Sunset
  [1.5, 0.2, 0, 0, 0, 0.1, 0.9, 0.1, 0, 0, -0.1, -0.2, 1.3, 0, 0, 0, 0, 0, 1, 0],
  // Noir
  [1.3, -0.3, 0.1, 0, 0, -0.1, 1.2, -0.1, 0, 0, 0.1, -0.2, 1.3, 0, 0, 0, 0, 0, 1, 0],
  // Dreamy
  [1.1, 0.1, 0.1, 0, 0, 0.1, 1.1, 0.1, 0, 0, 0.1, 0.1, 1.1, 0, 15, 0, 0, 0, 1, 0],
  // Sepia
  [0.393, 0.769, 0.189, 0, 0, 0.349, 0.686, 0.168, 0, 0, 0.272, 0.534, 0.131, 0, 0, 0, 0, 0, 1, 0],
  // Radium
  [
    1.438,
    -0.062,
    -0.062,
    0,
    0,
    -0.122,
    1.378,
    -0.122,
    0,
    0,
    -0.016,
    -0.016,
    1.483,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ],
  // Aqua
  [
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.7873,
    0.2848,
    0.9278,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ],
  // Purple Haze
  [1.3, 0, 1.2, 0, 0, 0, 1.1, 0, 0, 0, 0.2, 0, 1.3, 0, 0, 0, 0, 0, 1, 0],
  // Lemonade
  [1.2, 0.1, 0, 0, 0, 0, 1.1, 0.2, 0, 0, 0.1, 0, 0.7, 0, 0, 0, 0, 0, 1, 0],
  // Caramel
  [1.6, 0.2, 0, 0, 0, 0.1, 1.3, 0.1, 0, 0, 0, 0.1, 0.9, 0, 0, 0, 0, 0, 1, 0],
  // Peachy
  [1.3, 0.5, 0, 0, 0, 0.2, 1.1, 0.3, 0, 0, 0.1, 0.1, 1.2, 0, 0, 0, 0, 0, 1, 0],
  // Neon
  [1, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 1, 0],
  // Cold Morning
  [0.9, 0.1, 0.2, 0, 0, 0, 1, 0.1, 0, 0, 0.1, 0, 1.2, 0, 0, 0, 0, 0, 1, 0],
  // Lush
  [0.9, 0.2, 0, 0, 0, 0, 1.2, 0, 0, 0, 0, 0, 1.1, 0, 0, 0, 0, 0, 1, 0],
  // Urban Neon
  [1.1, 0, 0.3, 0, 0, 0, 0.9, 0.3, 0, 0, 0.3, 0.1, 1.2, 0, 0, 0, 0, 0, 1, 0],
  // Monochrome
  [0.6, 0.2, 0.2, 0, 0, 0.2, 0.6, 0.2, 0, 0, 0.2, 0.2, 0.7, 0, 0, 0, 0, 0, 1, 0],
];

const List<ColorFilter> filters = [
  // Original (index 0)
  ColorFilter.matrix([1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0]),
  // Vintage
  ColorFilter.matrix([0.8, 0.1, 0.1, 0, 20, 0.1, 0.8, 0.1, 0, 20, 0.1, 0.1, 0.8, 0, 20, 0, 0, 0, 1, 0]),
  // Mood
  ColorFilter.matrix([1.2, 0.1, 0.1, 0, 10, 0.1, 1, 0.1, 0, 10, 0.1, 0.1, 1, 0, 10, 0, 0, 0, 1, 0]),
  // Crisp
  ColorFilter.matrix([1.2, 0, 0, 0, 0, 0, 1.2, 0, 0, 0, 0, 0, 1.2, 0, 0, 0, 0, 0, 1, 0]),
  // Cool
  ColorFilter.matrix([0.9, 0, 0.2, 0, 0, 0, 1, 0.1, 0, 0, 0.1, 0, 1.2, 0, 0, 0, 0, 0, 1, 0]),
  // Blush
  ColorFilter.matrix([1.1, 0.1, 0.1, 0, 10, 0.1, 1, 0.1, 0, 10, 0.1, 0.1, 1, 0, 5, 0, 0, 0, 1, 0]),
  // Sunkissed
  ColorFilter.matrix([1.3, 0, 0.1, 0, 15, 0, 1.1, 0.1, 0, 10, 0, 0, 0.9, 0, 5, 0, 0, 0, 1, 0]),
  // Fresh
  ColorFilter.matrix([1.2, 0, 0, 0, 20, 0, 1.2, 0, 0, 20, 0, 0, 1.1, 0, 20, 0, 0, 0, 1, 0]),
  // Classic
  ColorFilter.matrix([1.1, 0, -0.1, 0, 10, -0.1, 1.1, 0.1, 0, 5, 0, -0.1, 1.1, 0, 0, 0, 0, 0, 1, 0]),
  // Lomo-ish
  ColorFilter.matrix([1.5, 0, 0.1, 0, 0, 0, 1.45, 0, 0, 0, 0.1, 0, 1.3, 0, 0, 0, 0, 0, 1, 0]),
  // Nashville
  ColorFilter.matrix([1.2, 0.15, -0.15, 0, 15, 0.1, 1.1, 0.1, 0, 10, -0.05, 0.2, 1.25, 0, 5, 0, 0, 0, 1, 0]),
  // Valencia
  ColorFilter.matrix([1.15, 0.1, 0.1, 0, 20, 0.1, 1.1, 0, 0, 10, 0.1, 0.1, 1.2, 0, 5, 0, 0, 0, 1, 0]),
  // Clarendon
  ColorFilter.matrix([1.2, 0, 0, 0, 10, 0, 1.25, 0, 0, 10, 0, 0, 1.3, 0, 10, 0, 0, 0, 1, 0]),
  // Moon
  ColorFilter.matrix([0.33, 0.33, 0.33, 0, 0, 0.33, 0.33, 0.33, 0, 0, 0.33, 0.33, 0.33, 0, 0, 0, 0, 0, 1, 0]),
  // Willow
  ColorFilter.matrix([0.5, 0.5, 0.5, 0, 20, 0.5, 0.5, 0.5, 0, 20, 0.5, 0.5, 0.5, 0, 20, 0, 0, 0, 1, 0]),
  // Kodak
  ColorFilter.matrix([1.3, 0.1, -0.1, 0, 10, 0, 1.25, 0.1, 0, 10, 0, -0.1, 1.1, 0, 5, 0, 0, 0, 1, 0]),
  // Frost
  ColorFilter.matrix([0.8, 0.2, 0.1, 0, 0, 0.2, 1.1, 0.1, 0, 0, 0.1, 0.1, 1.2, 0, 10, 0, 0, 0, 1, 0]),
  // Night Vision
  ColorFilter.matrix([0.1, 0.95, 0.2, 0, 0, 0.1, 1.5, 0.1, 0, 0, 0.2, 0.7, 0, 0, 0, 0, 0, 0, 1, 0]),
  // Sunset
  ColorFilter.matrix([1.5, 0.2, 0, 0, 0, 0.1, 0.9, 0.1, 0, 0, -0.1, -0.2, 1.3, 0, 0, 0, 0, 0, 1, 0]),
  // Noir
  ColorFilter.matrix([1.3, -0.3, 0.1, 0, 0, -0.1, 1.2, -0.1, 0, 0, 0.1, -0.2, 1.3, 0, 0, 0, 0, 0, 1, 0]),
  // Dreamy
  ColorFilter.matrix([1.1, 0.1, 0.1, 0, 0, 0.1, 1.1, 0.1, 0, 0, 0.1, 0.1, 1.1, 0, 15, 0, 0, 0, 1, 0]),
  // Sepia
  ColorFilter.matrix([0.393, 0.769, 0.189, 0, 0, 0.349, 0.686, 0.168, 0, 0, 0.272, 0.534, 0.131, 0, 0, 0, 0, 0, 1, 0]),
  // Radium
  ColorFilter.matrix([
    1.438,
    -0.062,
    -0.062,
    0,
    0,
    -0.122,
    1.378,
    -0.122,
    0,
    0,
    -0.016,
    -0.016,
    1.483,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]),
  // Aqua
  ColorFilter.matrix([
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.7873,
    0.2848,
    0.9278,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]),
  // Purple Haze
  ColorFilter.matrix([1.3, 0, 1.2, 0, 0, 0, 1.1, 0, 0, 0, 0.2, 0, 1.3, 0, 0, 0, 0, 0, 1, 0]),
  // Lemonade
  ColorFilter.matrix([1.2, 0.1, 0, 0, 0, 0, 1.1, 0.2, 0, 0, 0.1, 0, 0.7, 0, 0, 0, 0, 0, 1, 0]),
  // Caramel
  ColorFilter.matrix([1.6, 0.2, 0, 0, 0, 0.1, 1.3, 0.1, 0, 0, 0, 0.1, 0.9, 0, 0, 0, 0, 0, 1, 0]),
  // Peachy
  ColorFilter.matrix([1.3, 0.5, 0, 0, 0, 0.2, 1.1, 0.3, 0, 0, 0.1, 0.1, 1.2, 0, 0, 0, 0, 0, 1, 0]),
  // Neon
  ColorFilter.matrix([1, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 1, 0]),
  // Cold Morning
  ColorFilter.matrix([0.9, 0.1, 0.2, 0, 0, 0, 1, 0.1, 0, 0, 0.1, 0, 1.2, 0, 0, 0, 0, 0, 1, 0]),
  // Lush
  ColorFilter.matrix([0.9, 0.2, 0, 0, 0, 0, 1.2, 0, 0, 0, 0, 0, 1.1, 0, 0, 0, 0, 0, 1, 0]),
  // Urban Neon
  ColorFilter.matrix([1.1, 0, 0.3, 0, 0, 0, 0.9, 0.3, 0, 0, 0.3, 0.1, 1.2, 0, 0, 0, 0, 0, 1, 0]),
  // Monochrome
  ColorFilter.matrix([0.6, 0.2, 0.2, 0, 0, 0.2, 0.6, 0.2, 0, 0, 0.2, 0.2, 0.7, 0, 0, 0, 0, 0, 1, 0]),
];

const List<String> filterNames = [
  'Original',
  'Vintage',
  'Mood',
  'Crisp',
  'Cool',
  'Blush',
  'Sunkissed',
  'Fresh',
  'Classic',
  'Lomo-ish',
  'Nashville',
  'Valencia',
  'Clarendon',
  'Moon',
  'Willow',
  'Kodak',
  'Frost',
  'Night Vision',
  'Sunset',
  'Noir',
  'Dreamy',
  'Sepia',
  'Radium',
  'Aqua',
  'Purple Haze',
  'Lemonade',
  'Caramel',
  'Peachy',
  'Neon',
  'Cold Morning',
  'Lush',
  'Urban Neon',
  'Monochrome',
];

/// ColorFilter matrix for identity (no change)
const List<double> identityMatrix = [
  1, 0, 0, 0, 0,
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 1, 0,
];

const ColorFilter identityFilter = ColorFilter.matrix(identityMatrix);

/// Returns a ColorFilter with intensity applied by lerping between identity and the filter matrix.
/// This creates a new ColorFilter with a blended matrix.
ColorFilter applyFilterIntensity(int filterIndex, double intensity) {
  if (intensity <= 0.0) return identityFilter;
  if (intensity >= 1.0) return filters[filterIndex];
  
  if (filterIndex <= 0 || filterIndex >= filterMatrices.length) {
    return identityFilter;
  }
  
  // Lerp between identity and filter matrix
  final filterMatrix = filterMatrices[filterIndex];
  final blended = List<double>.generate(20, (i) {
    return identityMatrix[i] + (filterMatrix[i] - identityMatrix[i]) * intensity;
  });
  
  return ColorFilter.matrix(blended);
}
