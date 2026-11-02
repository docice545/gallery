import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/row_layout.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_scroll_target.dart';

void main() {
  FixedRowLayout mosaic(
    List<double> ratios, {
    double width = 390,
    int columns = 3,
    double spacing = 3,
    double target = 200,
    double minimum = 96,
    double maximum = 320,
  }) => FixedRowLayout.justified(
    width: width,
    aspectRatios: ratios,
    columnCount: columns,
    spacing: spacing,
    targetHeight: target,
    minimumHeight: minimum,
    maximumHeight: maximum,
  );

  void verify(FixedRowLayout layout) {
    var nextAsset = 0;
    for (var row = 0; row < layout.rowCount; row++) {
      final height = layout.heightForRow(row);
      final widths = layout.widthsForRow(row);
      expect(layout.firstAssetIndexForRow(row), nextAsset);
      expect(layout.assetCountForRow(row), widths.length);
      expect(widths, isNotEmpty);
      expect(widths.every((width) => width.isFinite && width > 0), isTrue);
      expect(height.isFinite && height > 0, isTrue);
      final occupied = widths.fold(0.0, (sum, width) => sum + width) + layout.spacing * (widths.length - 1);
      if (layout.isJustifiedRow(row)) {
        expect(occupied, closeTo(layout.width, 1e-8));
      } else {
        expect(row, layout.rowCount - 1);
        expect(occupied, lessThan(layout.width));
      }
      final offset = layout.offsetForRow(row);
      expect(layout.rowForOffset(offset), row);
      expect(layout.rowForOffset(offset + height / 2), row);
      for (var index = nextAsset; index < nextAsset + widths.length; index++) {
        expect(layout.rowForAssetIndex(index), row);
      }
      nextAsset += widths.length;
    }
    expect(nextAsset, layout.assetCount);
    expect(layout.extent, layout.rowCount == 0 ? 0 : layout.offsetForRow(layout.rowCount) - layout.spacing);
  }

  test('a single photograph fills the width with bounded cover-crop height', () {
    final landscape = mosaic([1.5]);
    expect(landscape.rowCount, 1);
    expect(landscape.isJustifiedRow(0), isTrue);
    expect(landscape.heightForRow(0), 260);
    expect(landscape.widthsForRow(0), [390]);
    final portrait = mosaic([.45]);
    expect(portrait.rowCount, 1);
    expect(portrait.isJustifiedRow(0), isTrue);
    expect(portrait.heightForRow(0), 320);
    expect(portrait.widthsForRow(0), [390]);
    verify(landscape);
    verify(portrait);
  });

  test('two photographs share the same computed height and fill the exact available width', () {
    final layout = mosaic([1, 1]);
    expect(layout.rowCount, 1);
    expect(layout.heightForRow(0), 193.5);
    expect(layout.widthsForRow(0), [193.5, 193.5]);
    verify(layout);
  });

  test('three phone screenshots use their portrait proportions and fill a bounded final row', () {
    final layout = mosaic([.45, .46, .44]);
    expect(layout.rowCount, 1);
    expect(layout.heightForRow(0), closeTo((390 - 6) / 1.35, 1e-8));
    expect(layout.heightForRow(0), lessThanOrEqualTo(320));
    expect(layout.widthsForRow(0)[0] / layout.heightForRow(0), closeTo(.45, 1e-8));
    verify(layout);
  });

  test('mixed portrait and landscape rows use aspect sums, preserve order and vary their item count', () {
    final ratios = [.5, .5, .5, .5, 2.0, 1.8, 1.5, 1.0];
    final layout = mosaic(ratios);
    final counts = <int>{};
    for (var row = 0; row < layout.rowCount; row++) {
      final first = layout.firstAssetIndexForRow(row);
      final widths = layout.widthsForRow(row);
      counts.add(widths.length);
      for (var index = 0; index < widths.length; index++) {
        expect(widths[index] / layout.heightForRow(row), closeTo(ratios[first + index], 1e-8));
      }
    }
    expect(counts.length, greaterThan(1));
    verify(layout);
  });

  test('a long sequence of portraits changes row counts rather than compressing every source into square tiles', () {
    final layout = mosaic(List.filled(40, .5));
    expect(layout.rowCount, 10);
    expect(layout.assetCountForRow(0), 4);
    expect(layout.heightForRow(0), 95.25 * 2);
    verify(layout);
  });

  test('extreme and unknown proportions have finite bounded geometry and no empty cells', () {
    final layout = mosaic([.00001, 100000, double.nan, double.infinity, -1, 0, .25, 3, .4, 1.8]);
    verify(layout);
    for (var row = 0; row < layout.rowCount; row++) {
      expect(layout.heightForRow(row), inInclusiveRange(96, 320));
      for (final width in layout.widthsForRow(row)) {
        expect(width, greaterThanOrEqualTo(72 - 1e-8));
      }
    }
  });

  test('a final incomplete row keeps its natural width at the target height', () {
    final layout = mosaic([1, 1, .25]);
    expect(layout.rowCount, 2);
    expect(layout.isJustifiedRow(0), isTrue);
    expect(layout.isJustifiedRow(1), isFalse);
    expect(layout.widthsForRow(1), [72]);
    expect(layout.heightForRow(1), 200);
    verify(layout);
  });

  test('an extreme portrait beside a panorama keeps both selection and media badges usable', () {
    final layout = mosaic([.25, 3.0]);
    expect(layout.rowCount, 1);
    expect(layout.widthsForRow(0), [72, 315]);
    verify(layout);
    final ordinary = mosaic([.5, 2.0]);
    expect(ordinary.widthsForRow(0)[0] / ordinary.heightForRow(0), closeTo(.5, 1e-8));
    expect(ordinary.widthsForRow(0)[1] / ordinary.heightForRow(0), closeTo(2.0, 1e-8));
  });

  test('row bounds and exact sums hold across compact screens, zoom levels and pathological ratios', () {
    final random = math.Random(17);
    for (final width in [200.0, 320.0, 390.0, 844.0]) {
      for (var columns = 1; columns <= 8; columns++) {
        final nominal = (width - 3 * (columns - 1)) / columns;
        final target = (nominal * 1.55).clamp(96.0, 280.0);
        final minimum = (target * .55).clamp(48.0, 120.0);
        final maximum = math.max(target, (target * 1.6).clamp(160.0, 320.0));
        final ratios = List.generate(100, (index) {
          if (index % 7 == 0) {
            return 1e-9;
          }
          if (index % 7 == 1) {
            return 1e9;
          }
          return random.nextDouble() * 3 + .1;
        });
        final layout = FixedRowLayout.justified(width: width, aspectRatios: ratios, columnCount: columns, spacing: 3);
        verify(layout);
        for (var row = 0; row < layout.rowCount; row++) {
          expect(layout.heightForRow(row), inInclusiveRange(minimum, maximum));
          final available = width - 3 * (layout.assetCountForRow(row) - 1);
          final floor = math.min(72.0, available / layout.assetCountForRow(row));
          for (final cell in layout.widthsForRow(row)) {
            expect(cell, greaterThanOrEqualTo(floor - 1e-8));
          }
        }
      }
    }
  });

  test('cached rows are immutable and repeated layout queries do not recreate cell lists', () {
    final source = <double>[1, 1, .5, 1.5];
    final layout = mosaic(source);
    final original = layout.widthsForRow(0);
    source[0] = 3;
    expect(layout.widthsForRow(0), same(original));
    expect(() => original[0] = 0, throwsUnsupportedError);
    expect(layout, mosaic([1, 1, .5, 1.5]));
    expect(layout.hashCode, mosaic([1, 1, .5, 1.5]).hashCode);
    expect(layout, isNot(mosaic([.5, 1, .5, 1.5])));
  });

  test(
    'viewport widths and zoom column counts produce valid geometry without a frame-time full-library calculation',
    () {
      final ratios = List.generate(50_000, (index) => [.45, 1.5, .75, 1.0, 2.0][index % 5]);
      for (final width in [320.0, 390.0, 844.0]) {
        for (final columns in [2, 3, 5]) {
          final layout = FixedRowLayout.justified(width: width, aspectRatios: ratios, columnCount: columns, spacing: 3);
          expect(layout.assetCount, ratios.length);
          var next = 0;
          for (var row = 0; row < layout.rowCount; row++) {
            expect(layout.firstAssetIndexForRow(row), next);
            next += layout.assetCountForRow(row);
          }
          expect(next, ratios.length);
          final random = math.Random(42);
          for (var sample = 0; sample < 100; sample++) {
            final index = random.nextInt(ratios.length);
            final row = layout.rowForAssetIndex(index);
            expect(layout.firstAssetIndexForRow(row), lessThanOrEqualTo(index));
            expect(layout.firstAssetIndexForRow(row) + layout.assetCountForRow(row), greaterThan(index));
            expect(layout.rowForOffset(layout.offsetForRow(row)), row);
            expect(layout.widthsForRow(row), same(layout.widthsForRow(row)));
          }
        }
      }
      expect(mosaic([]).rowCount, 0);
      expect(mosaic([]).extent, 0);
    },
  );

  test('segment extents, row targeting and date boundaries share the exact cached mosaic', () {
    final segments = FixedSegmentBuilder(
      buckets: [
        TimeBucket(date: DateTime(2026, 11, 2), assetCount: 5, aspectRatios: [.5, .5, .5, .5, 1.5]),
        TimeBucket(date: DateTime(2026, 11, 1), assetCount: 2, aspectRatios: [1, 1]),
        TimeBucket(date: DateTime(2025, 11, 30), assetCount: 1, aspectRatios: [1.5]),
        TimeBucket(date: DateTime(2025, 10, 31), assetCount: 1, aspectRatios: [1.5]),
      ],
      tileHeight: 128,
      columnCount: 3,
      spacing: 3,
      denseLayout: true,
    ).generate();
    final first = segments.first as FixedSegment;
    expect(first.rows, same(first.rows));
    expect(first.header, HeaderType.monthAndDay);
    expect(segments[1].header, HeaderType.day);
    expect(segments[2].header, HeaderType.monthAndDay);
    expect(segments[3].header, HeaderType.monthAndDay);
    for (var index = 0; index < first.bucket.assetCount; index++) {
      final row = first.rows.rowForAssetIndex(index);
      final offset = first.gridOffset + first.rows.offsetForRow(row);
      expect(assetRowOffset(segment: first, assetIndexInTimeline: index, columnCount: 3), offset);
      expect(first.getMinChildIndexForScrollOffset(offset), first.gridIndex + row);
      expect(first.getMaxChildIndexForScrollOffset(offset + 1), first.gridIndex + row);
    }
    for (var index = 0; index < segments.length - 1; index++) {
      expect(segments[index].endOffset, segments[index + 1].startOffset);
      expect(segments[index].indexToLayoutOffset(segments[index].lastIndex + 1), segments[index].endOffset);
    }
  });

  test('equal-count metadata corrections invalidate segment geometry but an unchanged source stays equal', () {
    FixedSegment segment(List<double> ratios) =>
        FixedSegmentBuilder(
              buckets: [Bucket(assetCount: ratios.length, aspectRatios: ratios)],
              tileHeight: 128,
              columnCount: 3,
              spacing: 3,
              denseLayout: true,
            ).generate().single
            as FixedSegment;
    final initial = segment([1, 1, 1, 1]);
    expect(initial, segment([1, 1, 1, 1]));
    expect(initial, isNot(segment([.5, .5, .5, .5])));
  });
}
