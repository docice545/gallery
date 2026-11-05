import 'dart:math' as math;
import 'dart:ui' show Rect;

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

  /// Cached adaptive mosaic for one date bucket. The bounded candidate set
  /// contains filled rows of 2–3 cells on phones and balanced three-cell
  /// compositions. Bounded local planning avoids singleton tails without
  /// moving assets across dates or rearranging a distant earlier viewport.
  /// Geometry depends only on indexed dimensions, never
  /// thumbnail readiness or selection. Construction is O(n); scroll lookup
  /// remains binary search over the cached block offsets.
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
    final target = targetHeight ?? (nominalHeight * 1.25).clamp(88.0, 192.0);
    final minimum = minimumHeight ?? (target * .55).clamp(64.0, 104.0);
    final maximum = maximumHeight ?? math.max(target, (256.0 - columnCount * 8).clamp(176.0, 240.0));
    final blockMaximum = math.min(280.0, maximum * 1.25);
    final minimumWidth = math.min(104.0, (width - spacing * 2) / 3);
    final maxCount = width < 600 ? 3 : (width / 130).floor().clamp(3, 8);
    final preferredCount = columnCount.clamp(2, maxCount);
    assert(target.isFinite && target > 0);
    assert(minimum > 0 && minimum <= target);
    assert(maximum.isFinite && maximum >= target);
    final ratios = [for (final ratio in aspectRatios) ratio.isFinite && ratio > 0 ? ratio.clamp(.25, 4.0) : 1.0];
    final rows = <_JustifiedRow>[];
    final offsets = <double>[0];

    _JustifiedRow regular(int first, int count) {
      final source = ratios.sublist(first, first + count);
      final available = width - spacing * (count - 1);
      final height = (available / source.sum).clamp(minimum, maximum);
      final widths = _boundedWidths(source, available, minimumWidth: minimumWidth);
      var left = 0.0;
      final cells = <Rect>[];
      for (final cellWidth in widths) {
        cells.add(Rect.fromLTWH(left, 0, cellWidth, height));
        left += cellWidth + spacing;
      }
      return _JustifiedRow(first: first, height: height, cells: cells, justified: true);
    }

    double loss(Rect cell, double sourceRatio) {
      final displayed = cell.width / cell.height;
      return 1 - math.min(displayed / sourceRatio, sourceRatio / displayed);
    }

    _JustifiedRow? composition(int first, {required bool largeFirst}) {
      final large = largeFirst ? 0 : 2;
      final smallA = largeFirst ? 1 : 0;
      final smallB = largeFirst ? 2 : 1;
      final heroRatio = ratios[first + large];
      final a = ratios[first + smallA];
      final b = ratios[first + smallB];
      final inverse = 1 / a + 1 / b;
      final smallWidth = (width - spacing - heroRatio * spacing) / (1 + heroRatio * inverse);
      final largeWidth = width - spacing - smallWidth;
      // Balanced columns, not a large picture beside an unusably narrow strip.
      if (math.min(smallWidth, largeWidth) < minimumWidth ||
          math.min(smallWidth, largeWidth) / math.max(smallWidth, largeWidth) < .6) {
        return null;
      }
      final height = math.min(blockMaximum, smallWidth * inverse + spacing);
      final aHeight = (height - spacing) * (1 / a) / inverse;
      final bHeight = height - spacing - aHeight;
      if (math.min(aHeight, bHeight) < minimum) {
        return null;
      }
      final smallLeft = largeFirst ? largeWidth + spacing : 0.0;
      final big = Rect.fromLTWH(largeFirst ? 0 : smallWidth + spacing, 0, largeWidth, height);
      final top = Rect.fromLTWH(smallLeft, 0, smallWidth, aHeight);
      final bottom = Rect.fromLTWH(smallLeft, aHeight + spacing, smallWidth, bHeight);
      // Source traversal is stable: first+1/first+2 in the side column, or
      // first/first+1 in the left column followed by the large final item.
      final cells = largeFirst ? [big, top, bottom] : [top, bottom, big];
      for (var i = 0; i < cells.length; i++) {
        if (loss(cells[i], ratios[first + i]) > .30) {
          return null;
        }
      }
      return _JustifiedRow(first: first, height: height, cells: cells, justified: true);
    }

    double score(_JustifiedRow row, {bool compound = false}) {
      final losses = [for (var i = 0; i < row.cells.length; i++) loss(row.cells[i], ratios[row.first + i])];
      final deviation = (row.height - target) / target;
      final density = .2 * deviation * deviation * row.cells.length + .1 * (row.cells.length - preferredCount).abs();
      // Favor a well-fitting asymmetric composition when it preserves the
      // contents of differently shaped neighbors. Poorly cropped compositions
      // receive no such benefit; ordinary portrait/landscape runs stay rows.
      final compositionBenefit = compound ? 4 * (1 - losses.reduce(math.max) / .30) : 0.0;
      return losses.sum * 4 + density - compositionBenefit;
    }

    if (ratios.length == 1) {
      // A genuinely solitary date remains bounded. Portraits keep the compact
      // centered footprint; landscapes/panoramas never grow into giant cards.
      final ratio = ratios.single;
      final height = ratio < 1
          ? math.min(128.0, target)
          : (width / ratio).clamp(48.0, math.min(128.0, target)).toDouble();
      final cellWidth = ratio < 1 ? math.min(width, math.max(math.min(72.0, width), height * ratio)) : width;
      rows.add(
        _JustifiedRow(
          first: 0,
          height: height,
          cells: [Rect.fromLTWH((width - cellWidth) / 2, 0, cellWidth, height)],
          justified: cellWidth == width,
        ),
      );
    } else if (ratios.isNotEmpty) {
      // Solve consecutive short windows, not the entire date as one optimum.
      // Otherwise removing a middle item can change distant preceding rows and
      // move an unrelated viewport. Nine assets fit 2/3-cell partitions; a final
      // ten are kept together instead of leaving an artificial singleton.
      for (var start = 0; start < ratios.length;) {
        final remaining = ratios.length - start;
        final end = start + math.min<int>(remaining, remaining == 10 ? 10 : 9);
        final costs = List.filled(end - start + 1, double.infinity);
        final choices = List<_JustifiedRow?>.filled(end - start, null);
        costs[end - start] = 0;
        for (var first = end - 2; first >= start; first--) {
          void consider(_JustifiedRow? row, {bool compound = false}) {
            if (row == null) {
              return;
            }
            final rest = first + row.cells.length;
            final cost = score(row, compound: compound) + costs[rest - start];
            if (cost < costs[first - start]) {
              costs[first - start] = cost;
              choices[first - start] = row;
            }
          }

          for (var count = 2; count <= math.min(maxCount, end - first); count++) {
            if (end - first - count == 1) {
              continue;
            }
            consider(regular(first, count));
            if (count == 3) {
              consider(composition(first, largeFirst: true), compound: true);
              consider(composition(first, largeFirst: false), compound: true);
            }
          }
        }
        for (var first = start; first < end;) {
          final row = choices[first - start]!;
          rows.add(row);
          first += row.cells.length;
        }
        start = end;
      }
    }
    for (final row in rows) {
      offsets.add(offsets.last + row.height + spacing);
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
  static List<double> _boundedWidths(List<double> ratios, double available, {double minimumWidth = 72}) {
    final minimum = math.min(minimumWidth, available / ratios.length);
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

  /// Ordered, cached cell geometry. Null for the unchanged ordinary grid.
  List<Rect>? cellsForRow(int row) => _justifiedRows?[row].cells;

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
      ? (tileHeight * 1.55).clamp(96.0, 280.0)
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
      // A global sliver offset is converted back to a row-relative offset by
      // subtraction. Floating-point cancellation can put an exact row start a
      // fraction below its boundary and anchor the preceding row on the next
      // density change. Match the segment end-boundary tolerance; this is far
      // below a physical pixel and does not snap ordinary scrolling.
      if (offsetForRow(middle) <= offset + 1e-8) {
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
  _JustifiedRow({required this.first, required this.height, required List<Rect> cells, required this.justified})
    : cells = List.unmodifiable(cells),
      widths = List.unmodifiable(cells.map((cell) => cell.width));

  final int first;
  final double height;
  final List<double> widths;
  final List<Rect> cells;
  final bool justified;

  @override
  bool operator ==(Object other) =>
      other is _JustifiedRow &&
      other.first == first &&
      other.height == height &&
      other.justified == justified &&
      const ListEquality<Rect>().equals(other.cells, cells);

  @override
  int get hashCode => Object.hash(first, height, justified, const ListEquality<Rect>().hash(cells));
}
