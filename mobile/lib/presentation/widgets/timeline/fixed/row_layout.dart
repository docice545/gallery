import 'dart:math' as math;

import 'package:collection/collection.dart';

/// Cached row geometry shared by rendering, scroll targeting and selection.
///
/// The ordinary grid keeps its count-only geometry. The main Photos mosaic
/// uses [FixedRowLayout.justified] with ordered dimensions from the local index,
/// before any thumbnail is fetched or any visible row is built.
class FixedRowLayout {
  final int assetCount;
  final int columnCount;
  final double tileHeight;
  final double spacing;
  final bool denseLayout;
  final double? _width;
  final List<_JustifiedRow>? _justifiedRows;
  final List<double>? _offsets;

  const FixedRowLayout({
    required this.assetCount,
    required this.columnCount,
    required this.tileHeight,
    required this.spacing,
    this.denseLayout = false,
  }) : assert(columnCount > 0),
       _width = null,
       _justifiedRows = null,
       _offsets = null;

  const FixedRowLayout._({
    required this.assetCount,
    required this.columnCount,
    required this.tileHeight,
    required this.spacing,
    required this._width,
    required this._justifiedRows,
    required this._offsets,
  }) : denseLayout = true;

  /// Builds a linear-time justified mosaic. A completed row fills [width]; its
  /// cell width is its height multiplied by the normalized source aspect ratio.
  ///
  /// Pathological source dimensions are bounded (1:4 through 3:1), and cells
  /// narrower than 72 pixels receive a bounded cover crop for usable selection
  /// targets. Ordinary rows preserve their source aspect ratios. Unknown
  /// dimensions use a square. A final row
  /// which would exceed [maximumHeight] stays at [targetHeight] instead of
  /// stretching a lone portrait across the display.
  factory FixedRowLayout.justified({
    required double width,
    required List<double> aspectRatios,
    required int columnCount,
    required double spacing,
    double? targetHeight,
    double? minimumHeight,
    double? maximumHeight,
  }) {
    assert(width.isFinite && width > 0);
    assert(columnCount > 0);
    assert(spacing.isFinite && spacing >= 0);
    final nominalHeight = math.max(1.0, width - spacing * (columnCount - 1)) / columnCount;
    final target = targetHeight ?? (nominalHeight * 1.55).clamp(96.0, 280.0);
    final minimum = minimumHeight ?? (target * .55).clamp(48.0, 120.0);
    final maximum = maximumHeight ?? math.max(target, (target * 1.6).clamp(160.0, 320.0));
    assert(target.isFinite && target > 0);
    assert(minimum > 0 && minimum <= target);
    assert(maximum.isFinite && maximum >= target);
    final ratios = [for (final ratio in aspectRatios) ratio.isFinite && ratio > 0 ? ratio.clamp(.25, 3.0) : 1.0];
    final rows = <_JustifiedRow>[];
    final offsets = <double>[0];
    var first = 0;
    while (first < ratios.length) {
      var count = 0;
      var sum = 0.0;
      var previousHeight = double.infinity;
      var previousSum = 0.0;
      var rowHeight = 0.0;
      // Limit the search by the available width as well as by the target. Even
      // a long series of extreme portraits cannot produce negative cell space.
      final maxCount = math.max(1, ((width + spacing) / (72 + spacing)).floor());
      while (first + count < ratios.length && count < maxCount) {
        previousSum = sum;
        sum += ratios[first + count];
        count++;
        rowHeight = math.max(0.0, width - spacing * (count - 1)) / sum;
        if (rowHeight <= target) {
          if (count > 1 &&
              ((previousHeight <= maximum &&
                      previousHeight >= minimum &&
                      (previousHeight - target).abs() < (rowHeight - target).abs()) ||
                  rowHeight < minimum)) {
            count--;
            sum = previousSum;
            rowHeight = previousHeight;
          }
          break;
        }
        previousHeight = rowHeight;
      }
      final last = first + count == ratios.length;
      var justified = !last || rowHeight <= maximum;
      final available = math.max(0.0, width - spacing * (count - 1));
      List<double> widths;
      final rowRatios = ratios.sublist(first, first + count);
      if (justified) {
        // A normal row keeps the exact source proportions. If no partition can
        // meet both height bounds, cover-crop its cells rather than create an
        // excessively tall/short row. Images are never geometrically stretched.
        rowHeight = rowHeight.clamp(minimum, maximum);
        widths = _boundedWidths(rowRatios, available);
      } else {
        rowHeight = target;
        final minimumWidth = math.min(72.0, available / count);
        widths = [for (final ratio in rowRatios) math.max(minimumWidth, rowHeight * ratio)];
        if (widths.fold(0.0, (sum, width) => sum + width) >= available) {
          widths = _boundedWidths(rowRatios, available);
          justified = true;
        }
      }
      rows.add(_JustifiedRow(first: first, height: rowHeight, widths: List.unmodifiable(widths), justified: justified));
      offsets.add(offsets.last + rowHeight + spacing);
      first += count;
    }
    return FixedRowLayout._(
      assetCount: ratios.length,
      columnCount: columnCount,
      tileHeight: nominalHeight,
      spacing: spacing,
      width: width,
      justifiedRows: List.unmodifiable(rows),
      offsets: List.unmodifiable(offsets),
    );
  }

  /// Keep the existing timeline badges/select targets usable for extreme
  /// portraits beside a panorama. Water filling changes only undersized cells
  /// and the remaining proportional widths; ordinary rows retain their ratios.
  static List<double> _boundedWidths(List<double> ratios, double available) {
    final minimum = math.min(72.0, available / ratios.length);
    final widths = List.filled(ratios.length, 0.0);
    final fixed = List.filled(ratios.length, false);
    var remaining = available;
    var weight = ratios.fold(0.0, (sum, ratio) => sum + ratio);
    while (weight > 0) {
      var changed = false;
      final scale = remaining / weight;
      for (var index = 0; index < ratios.length; index++) {
        if (!fixed[index] && ratios[index] * scale < minimum) {
          fixed[index] = true;
          widths[index] = minimum;
          remaining -= minimum;
          weight -= ratios[index];
          changed = true;
        }
      }
      if (!changed) {
        for (var index = 0; index < ratios.length; index++) {
          if (!fixed[index]) {
            widths[index] = ratios[index] * remaining / weight;
          }
        }
        break;
      }
    }
    // Absorb subpixel arithmetic only, without accumulating a trailing gap.
    widths[widths.length - 1] = available - widths.take(widths.length - 1).fold(0.0, (sum, width) => sum + width);
    return widths;
  }

  double get width => _width ?? tileHeight * columnCount + spacing * (columnCount - 1);
  int get rowCount => _justifiedRows?.length ?? (assetCount / columnCount).ceil();
  int get _smallRowCount => rowCount == 0 ? 0 : assetCount ~/ rowCount;
  int get _largeRows => rowCount == 0 ? 0 : assetCount % rowCount;

  bool isJustifiedRow(int row) => _justifiedRows?[row].justified ?? true;

  List<double> widthsForRow(int row) =>
      _justifiedRows?[row].widths ?? List.filled(assetCountForRow(row), tileHeight, growable: false);

  int assetCountForRow(int row) =>
      _justifiedRows?[row].widths.length ??
      (denseLayout
          ? _smallRowCount + (row < _largeRows ? 1 : 0)
          : math.min(columnCount, assetCount - row * columnCount));

  int firstAssetIndexForRow(int row) =>
      _justifiedRows?[row].first ??
      (denseLayout ? row * _smallRowCount + math.min(row, _largeRows) : row * columnCount);

  int rowForAssetIndex(int index) {
    if (_justifiedRows != null) {
      var low = 0;
      var high = rowCount;
      while (low < high) {
        final middle = (low + high) ~/ 2;
        if (_justifiedRows[middle].first <= index) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      return math.max(0, low - 1);
    }
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

  double heightForRow(int row) => _justifiedRows?[row].height ?? _heightForCount(assetCountForRow(row));

  double offsetForRow(int row) {
    if (_offsets != null) {
      return _offsets[row];
    }
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

  @override
  bool operator ==(Object other) =>
      other is FixedRowLayout &&
      other.assetCount == assetCount &&
      other.columnCount == columnCount &&
      other.tileHeight == tileHeight &&
      other.spacing == spacing &&
      other.denseLayout == denseLayout &&
      other.width == width &&
      const ListEquality<_JustifiedRow>().equals(other._justifiedRows, _justifiedRows);

  @override
  int get hashCode => Object.hash(
    assetCount,
    columnCount,
    tileHeight,
    spacing,
    denseLayout,
    width,
    const ListEquality<_JustifiedRow>().hash(_justifiedRows),
  );

  /// Legacy width distribution for ordinary fixed segments that opt in without
  /// an indexed aspect summary. New Photos segments use cached [widthsForRow].
  static List<double> justifiedWidths({
    required double width,
    required double spacing,
    required List<double> aspectRatios,
  }) {
    if (aspectRatios.isEmpty) {
      return const [];
    }
    final weights = aspectRatios.map((ratio) => ratio.isFinite && ratio > 0 ? ratio.clamp(0.35, 2.5) : 1.0).toList();
    final availableWidth = math.max(0.0, width - spacing * (weights.length - 1));
    final minimumWidth = math.min(72.0, availableWidth / weights.length);
    final remainingWidth = availableWidth - minimumWidth * weights.length;
    final sum = weights.fold(0.0, (sum, weight) => sum + weight);
    final widths = weights.map((weight) => minimumWidth + remainingWidth * weight / sum).toList();
    widths[widths.length - 1] = availableWidth - widths.take(widths.length - 1).fold(0.0, (sum, value) => sum + value);
    return widths;
  }
}

class _JustifiedRow {
  const _JustifiedRow({required this.first, required this.height, required this.widths, required this.justified});

  final int first;
  final double height;
  final List<double> widths;
  final bool justified;

  @override
  bool operator ==(Object other) =>
      other is _JustifiedRow &&
      other.first == first &&
      other.height == height &&
      other.justified == justified &&
      const ListEquality<double>().equals(other.widths, widths);

  @override
  int get hashCode => Object.hash(first, height, justified, const ListEquality<double>().hash(widths));
}
