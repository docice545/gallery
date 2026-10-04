import 'dart:math' as math;

/// Geometry based only on bucket counts, so lazy asset loading never moves rows.
/// Dense rows share the available width; widths within a loaded row use its
/// existing asset metadata, with cover cropping for a predictable row height.
class FixedRowLayout {
  final int assetCount;
  final int columnCount;
  final double tileHeight;
  final double spacing;
  final bool denseLayout;

  const FixedRowLayout({
    required this.assetCount,
    required this.columnCount,
    required this.tileHeight,
    required this.spacing,
    this.denseLayout = false,
  }) : assert(columnCount > 0);

  double get width => tileHeight * columnCount + spacing * (columnCount - 1);
  int get rowCount => (assetCount / columnCount).ceil();
  int get _smallRowCount => rowCount == 0 ? 0 : assetCount ~/ rowCount;
  int get _largeRows => rowCount == 0 ? 0 : assetCount % rowCount;

  int assetCountForRow(int row) =>
      denseLayout ? _smallRowCount + (row < _largeRows ? 1 : 0) : math.min(columnCount, assetCount - row * columnCount);

  int firstAssetIndexForRow(int row) =>
      denseLayout ? row * _smallRowCount + math.min(row, _largeRows) : row * columnCount;

  int rowForAssetIndex(int index) {
    if (!denseLayout) {
      return index ~/ columnCount;
    }
    final largeRowAssets = _largeRows * (_smallRowCount + 1);
    return index < largeRowAssets
        ? index ~/ (_smallRowCount + 1)
        : _largeRows + (index - largeRowAssets) ~/ _smallRowCount;
  }

  double _heightForCount(int count) => !denseLayout
      ? tileHeight
      : count == 1
      ? math.min(width * 0.75, 360)
      : math.min((width - spacing * (count - 1)) / count, 280);

  double heightForRow(int row) => _heightForCount(assetCountForRow(row));

  double offsetForRow(int row) {
    if (!denseLayout) {
      return row * (tileHeight + spacing);
    }
    final largeRows = math.min(row, _largeRows);
    return largeRows * _heightForCount(_smallRowCount + 1) +
        (row - largeRows) * _heightForCount(_smallRowCount) +
        row * spacing;
  }

  double get extent => rowCount == 0 ? 0 : offsetForRow(rowCount) - spacing;

  /// The last row whose start precedes [offset]. No per-asset/list allocation.
  int rowForOffset(double offset) {
    int low = 0;
    int high = rowCount;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (offsetForRow(middle) <= offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return math.max(0, low - 1);
  }

  static List<double> justifiedWidths({
    required double width,
    required double spacing,
    required List<double> aspectRatios,
  }) {
    if (aspectRatios.isEmpty) {
      return const [];
    }
    // Bound panoramic/very tall assets so every tile remains usable for badges
    // and selection. Unknown or malformed dimensions use a square fallback.
    final weights = aspectRatios.map((ratio) => ratio.isFinite && ratio > 0 ? ratio.clamp(0.65, 1.65) : 1.0).toList();
    final availableWidth = math.max(0.0, width - spacing * (weights.length - 1));
    final minimumWidth = math.min(72.0, availableWidth / weights.length);
    final remainingWidth = availableWidth - minimumWidth * weights.length;
    final sum = weights.fold(0.0, (sum, weight) => sum + weight);
    final widths = weights.map((weight) => minimumWidth + remainingWidth * weight / sum).toList();
    // Absorb floating point rounding into the final tile to fill the row exactly.
    widths[widths.length - 1] = availableWidth - widths.take(widths.length - 1).fold(0.0, (sum, value) => sum + value);
    return widths;
  }
}
