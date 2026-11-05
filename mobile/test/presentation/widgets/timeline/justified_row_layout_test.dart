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
      final cells = layout.cellsForRow(row)!;
      expect(cells.length, widths.length);
      expect(cells.map((cell) => cell.width), orderedEquals(widths));
      for (var a = 0; a < cells.length; a++) {
        expect(cells[a].top, greaterThanOrEqualTo(0));
        expect(cells[a].bottom, lessThanOrEqualTo(height + 1e-8));
        for (var b = a + 1; b < cells.length; b++) {
          expect(cells[a].overlaps(cells[b]), isFalse);
        }
      }
      if (layout.isJustifiedRow(row)) {
        expect(cells.map((cell) => cell.left).reduce(math.min), closeTo(0, 1e-8));
        expect(cells.map((cell) => cell.right).reduce(math.max), closeTo(layout.width, 1e-8));
        for (var y = 8.0; y < height - 8; y += 16) {
          for (var x = 8.0; x < layout.width - 8; x += 16) {
            expect(cells.any((cell) => cell.inflate(layout.spacing / 2 + 1e-8).contains(Offset(x, y))), isTrue);
          }
        }
      } else {
        expect(layout.assetCount, 1);
        expect(cells.single.center.dx, closeTo(layout.width / 2, 1e-8));
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

  test('single landscapes fill width while solitary portraits keep a compact bounded footprint', () {
    final landscape = mosaic([1.5]);
    expect(landscape.rowCount, 1);
    expect(landscape.isJustifiedRow(0), isTrue);
    expect(landscape.heightForRow(0), 128);
    expect(landscape.widthsForRow(0), [390]);
    final portrait = mosaic([.45]);
    expect(portrait.rowCount, 1);
    expect(portrait.isJustifiedRow(0), isFalse);
    expect(portrait.heightForRow(0), 128);
    expect(portrait.widthsForRow(0), [72]);
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

  test('mixed rows preserve order with bounded cover crop and balanced cells', () {
    final ratios = [.5, .5, .5, .5, 2.0, 1.8, 1.5, 1.0];
    final layout = mosaic(ratios);
    final counts = <int>{};
    for (var row = 0; row < layout.rowCount; row++) {
      final first = layout.firstAssetIndexForRow(row);
      final widths = layout.widthsForRow(row);
      counts.add(widths.length);
      final cells = layout.cellsForRow(row)!;
      for (var index = 0; index < widths.length; index++) {
        final source = ratios[first + index];
        final display = cells[index].width / cells[index].height;
        expect(math.min(source / display, display / source), greaterThanOrEqualTo(.5));
      }
    }
    expect(counts, everyElement(inInclusiveRange(2, 3)));
    verify(layout);
  });

  test('a long sequence of portraits changes row counts rather than compressing every source into square tiles', () {
    final layout = mosaic(List.filled(40, .5));
    expect(layout.rowCount, 14);
    expect([
      for (var row = 0; row < layout.rowCount; row++) layout.assetCountForRow(row),
    ], everyElement(inInclusiveRange(2, 3)));
    expect(layout.cellsForRow(2)!.every((cell) => cell.height > cell.width), isTrue);
    verify(layout);
  });

  test('production density settings 2 through 5 order target sizes without requiring that many columns', () {
    // Exercise the production defaults: the mosaic helper deliberately injects
    // a fixed target and cannot detect a broken density-to-size mapping.
    for (final width in [320.0, 390.0, 844.0]) {
      double? previousHeight;
      int? previousRows;
      for (final density in [2, 3, 4, 5]) {
        final layout = FixedRowLayout.justified(
          width: width,
          aspectRatios: List.filled(60, 1.0),
          columnCount: density,
          spacing: 3,
        );
        verify(layout);
        if (previousHeight != null) {
          expect(layout.heightForRow(0), lessThanOrEqualTo(previousHeight));
          expect(layout.rowCount, lessThanOrEqualTo(previousRows!));
        }
        previousHeight = layout.heightForRow(0);
        previousRows = layout.rowCount;
      }
    }
    final screenshots = FixedRowLayout.justified(
      width: 390,
      aspectRatios: List.filled(20, .45),
      columnCount: 3,
      spacing: 3,
    );
    expect([
      for (var row = 0; row < screenshots.rowCount; row++) screenshots.assetCountForRow(row),
    ], everyElement(inInclusiveRange(2, 3)));
    for (final cell in screenshots.cellsForRow(0)!) {
      expect(cell.width, greaterThanOrEqualTo(104));
      expect(cell.height, lessThanOrEqualTo(280));
    }
    verify(screenshots);
  });

  test('small width growth keeps the nearest bounded mixed row', () {
    for (final width in [384.0, 390.0, 396.0]) {
      final layout = FixedRowLayout.justified(
        width: width,
        aspectRatios: [
          for (var i = 0; i < 4; i++) ...[.45, .75, 1.5, 1, .45, 2],
        ],
        columnCount: 2,
        spacing: 3,
      );
      expect(layout.assetCountForRow(0), 3);
      expect(layout.heightForRow(0), lessThanOrEqualTo(280));
      expect(layout.widthsForRow(0).every((value) => value >= 104), isTrue);
      for (var row = 0; row < layout.rowCount; row++) {
        expect(layout.heightForRow(row), lessThanOrEqualTo(320));
      }
      verify(layout);
    }
  });

  test('global sliver row offsets round-trip at exact boundaries in both presentations', () {
    for (final hideHeaders in [false, true]) {
      for (final density in [2, 3, 4, 5]) {
        final segments = FixedSegmentBuilder(
          buckets: [
            for (var day = 0; day < 6; day++)
              TimeBucket(
                date: DateTime(2026, 11, 3 - day),
                assetCount: 10,
                aspectRatios: [
                  for (var i = day * 10; i < (day + 1) * 10; i++) [.45, 1.5, .75][i % 3],
                ],
              ),
          ],
          tileHeight: (390 - 3 * (density - 1)) / density,
          columnCount: density,
          spacing: 3,
          denseLayout: true,
          hideDateHeaders: hideHeaders,
        ).generate().cast<FixedSegment>();
        for (final segment in segments) {
          for (var row = 0; row < segment.rows.rowCount; row++) {
            final child = segment.gridIndex + row;
            final globalOffset = segment.indexToLayoutOffset(child);
            expect(
              segment.getMinChildIndexForScrollOffset(globalOffset),
              child,
              reason: 'Exact row start must survive global-to-relative double subtraction',
            );
            if (row > 0) {
              expect(
                segment.getMinChildIndexForScrollOffset(globalOffset - .01),
                child - 1,
                reason: 'A real subpixel displacement must still select the preceding row',
              );
            }
          }
        }
      }
    }
  });

  test('a tall singleton cannot displace compact square pairs or triples', () {
    final layout = FixedRowLayout.justified(width: 390, aspectRatios: List.filled(24, 1), columnCount: 2, spacing: 3);
    expect([
      for (var row = 0; row < layout.rowCount; row++) layout.assetCountForRow(row),
    ], everyElement(inInclusiveRange(2, 3)));
    expect(layout.heightForRow(0), lessThanOrEqualTo(193.5));
    verify(layout);
  });

  test('density and viewport changes preserve mixed day boundaries and asset indices', () {
    final buckets = [
      TimeBucket(date: DateTime(2026, 11, 2), assetCount: 6, aspectRatios: [.45, 1.5, .75, .45, 2, 1]),
      TimeBucket(date: DateTime(2026, 11, 1), assetCount: 3, aspectRatios: [.45, .45, .45]),
      TimeBucket(date: DateTime(2026, 10, 31), assetCount: 2, aspectRatios: [1.5, .75]),
    ];
    for (final width in [320.0, 390.0, 844.0]) {
      for (final density in [2, 3, 4, 5]) {
        final segments = FixedSegmentBuilder(
          buckets: buckets,
          tileHeight: (width - 3 * (density - 1)) / density,
          columnCount: density,
          spacing: 3,
          denseLayout: true,
        ).generate().cast<FixedSegment>();
        expect(segments.map((segment) => segment.bucket), orderedEquals(buckets));
        expect(segments.map((segment) => segment.firstAssetIndex), [0, 6, 9]);
        expect(segments.map((segment) => segment.header), [
          HeaderType.monthAndDay,
          HeaderType.day,
          HeaderType.monthAndDay,
        ]);
        for (final segment in segments) {
          verify(segment.rows);
          expect(segment.rows.width, closeTo(width, 1e-8));
          for (var index = 0; index < segment.bucket.assetCount; index++) {
            final row = segment.rows.rowForAssetIndex(index);
            expect(
              assetRowOffset(
                segment: segment,
                assetIndexInTimeline: segment.firstAssetIndex + index,
                columnCount: density,
              ),
              segment.gridOffset +
                  segment.rows.offsetForRow(row) +
                  segment.rows.cellsForRow(row)![index - segment.rows.firstAssetIndexForRow(row)].top,
            );
          }
        }
      }
    }
  });

  test('immersive presentation removes header space without changing dates, mosaic rows or stack representatives', () {
    // The bucket source already collapses stacks to representative assets.
    final buckets = [
      TimeBucket(date: DateTime(2026, 11, 2), assetCount: 3, aspectRatios: [.45, 1.5, .75]),
      TimeBucket(date: DateTime(2026, 11, 1), assetCount: 2, aspectRatios: [1, .5]),
    ];
    for (final density in [2, 3, 4, 5]) {
      List<FixedSegment> build(bool immersive) => FixedSegmentBuilder(
        buckets: buckets,
        tileHeight: (390 - 3 * (density - 1)) / density,
        columnCount: density,
        spacing: 3,
        denseLayout: true,
        hideDateHeaders: immersive,
      ).generate().cast<FixedSegment>();
      final classic = build(false);
      final immersive = build(true);
      expect(immersive.last.endOffset, lessThan(classic.last.endOffset));
      for (var index = 0; index < buckets.length; index++) {
        expect(immersive[index].bucket, same(buckets[index]));
        expect(immersive[index].firstAssetIndex, classic[index].firstAssetIndex);
        expect(immersive[index].rows, classic[index].rows);
        expect(immersive[index].header, HeaderType.none);
        expect(immersive[index].headerExtent, 0);
        expect(classic[index].headerExtent, greaterThan(0));
        verify(immersive[index].rows);
      }
      expect(build(false), classic, reason: 'Returning to Classic restores the original grouped geometry');
    }
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

  test('an extreme portrait tail is absorbed into a filled bounded block', () {
    final layout = mosaic([3, 3, .25]);
    expect(layout.rowCount, 1);
    expect(layout.isJustifiedRow(0), isTrue);
    expect(layout.assetCountForRow(0), 3);
    expect(layout.widthsForRow(0).last, greaterThanOrEqualTo(104));
    expect(layout.heightForRow(0), lessThanOrEqualTo(280));
    verify(layout);
  });

  test('an extreme portrait beside a panorama keeps both selection and media badges usable', () {
    final layout = mosaic([.25, 3.0]);
    expect(layout.rowCount, 1);
    expect(layout.widthsForRow(0), [104, 283]);
    verify(layout);
    final ordinary = mosaic([.5, 2.0]);
    expect(ordinary.widthsForRow(0).first, 104);
    expect(ordinary.widthsForRow(0).last, 283);
    expect(ordinary.heightForRow(0), closeTo(387 / 2.5, 1e-8));
  });

  test('row bounds and exact sums hold across compact screens, zoom levels and pathological ratios', () {
    final random = math.Random(17);
    for (final width in [200.0, 320.0, 390.0, 844.0]) {
      for (var columns = 1; columns <= 8; columns++) {
        final nominal = (width - 3 * (columns - 1)) / columns;
        final target = (nominal * 1.25).clamp(88.0, 192.0);
        final minimum = (target * .55).clamp(64.0, 104.0);
        const maximum = 280.0;
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
          final floor = math.min(math.min(104.0, (width - 6) / 3), available / layout.assetCountForRow(row));
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
