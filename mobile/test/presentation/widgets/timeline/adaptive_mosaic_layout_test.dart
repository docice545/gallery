import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/row.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/row_layout.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_scroll_target.dart';

FixedRowLayout _layout(List<double> ratios, {int density = 3}) =>
    FixedRowLayout.justified(width: 390, aspectRatios: ratios, columnCount: density, spacing: 3);

void main() {
  for (final count in [1, 2, 3, 5, 7]) {
    for (final ratio in [9 / 16, 1.0, 16 / 9]) {
      test('Adaptive date of $count assets at aspect $ratio has bounded, usable, ordered cells', () {
        for (final density in [2, 3, 4, 5]) {
          final layout = _layout(List.filled(count, ratio), density: density);
          var index = 0;
          for (var row = 0; row < layout.rowCount; row++) {
            expect(layout.firstAssetIndexForRow(row), index);
            expect(layout.assetCountForRow(row), count == 1 ? 1 : inInclusiveRange(2, 3));
            expect(layout.heightForRow(row), lessThanOrEqualTo(count == 1 ? 128 : 280));
            final cells = layout.cellsForRow(row)!;
            for (final cell in cells) {
              expect(cell.width, greaterThanOrEqualTo(count == 1 ? 72 : 104));
              expect(cell.height, greaterThan(0));
              expect(cell.right, lessThanOrEqualTo(390.000001));
            }
            index += cells.length;
          }
          expect(index, count);
        }
      });
    }
  }

  test('two landscapes share a row; three portraits share a balanced row', () {
    final pair = _layout([16 / 9, 16 / 9]);
    expect(pair.rowCount, 1);
    expect(pair.widthsForRow(0), [193.5, 193.5]);
    expect(pair.heightForRow(0), closeTo(193.5 * 9 / 16, 1e-8));
    final triple = _layout(List.filled(3, 9 / 16));
    expect(triple.rowCount, 1);
    expect(triple.widthsForRow(0), [128, 128, 128]);
    expect(triple.cellsForRow(0)!.every((cell) => cell.top == 0), isTrue);
  });

  for (final largeFirst in [true, false]) {
    test('compound block chooses the balanced ${largeFirst ? 'left' : 'right'} large cell', () {
      final ratios = largeFirst ? [9 / 16, 16 / 9, 16 / 9] : [16 / 9, 16 / 9, 9 / 16];
      final layout = _layout(ratios);
      expect(layout.rowCount, 1);
      final cells = layout.cellsForRow(0)!;
      final large = cells[largeFirst ? 0 : 2];
      final top = cells[largeFirst ? 1 : 0];
      final bottom = cells[largeFirst ? 2 : 1];
      expect(large.height, closeTo(top.height + bottom.height + 3, 1e-8));
      expect(top.left, bottom.left);
      expect(bottom.top, closeTo(top.bottom + 3, 1e-8));
      expect(largeFirst ? top.left - large.right : large.left - top.right, closeTo(3, 1e-8));
      for (var i = 0; i < cells.length; i++) {
        final display = cells[i].width / cells[i].height;
        expect(math.min(display / ratios[i], ratios[i] / display), greaterThanOrEqualTo(.7));
      }
    });
  }

  for (final direction in TextDirection.values) {
    testWidgets('compound render and tap regions use the cached cells in $direction', (tester) async {
      final layout = _layout([16 / 9, 16 / 9, 9 / 16]);
      final cells = layout.cellsForRow(0)!;
      final taps = <int>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: direction,
          child: Center(
            child: SizedBox(
              width: 390,
              child: TimelineRow(
                height: layout.heightForRow(0),
                widths: layout.widthsForRow(0),
                cells: cells,
                spacing: 3,
                textDirection: direction,
                children: [
                  for (var i = 0; i < cells.length; i++)
                    GestureDetector(
                      key: ValueKey(i),
                      onTap: () => taps.add(i),
                      child: const ColoredBox(color: Colors.blue),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      final origin = tester.getTopLeft(find.byType(TimelineRow));
      for (var i = 0; i < cells.length; i++) {
        final rect = tester.getRect(find.byKey(ValueKey(i)));
        expect(rect.size, cells[i].size);
        expect(rect.top - origin.dy, closeTo(cells[i].top, 1e-8));
        expect(
          rect.left - origin.dx,
          closeTo(direction == TextDirection.ltr ? cells[i].left : 390 - cells[i].right, 1e-8),
        );
        await tester.tapAt(rect.center);
      }
      expect(taps, [0, 1, 2]);
      expect(tester.takeException(), isNull);
    });
  }

  test('Samsung five compose across photo/video orientations, never across dates', () {
    final buckets = [
      TimeBucket(date: DateTime(2026, 11, 5), assetCount: 5, aspectRatios: [16 / 9, 16 / 9, 9 / 16, 9 / 16, 9 / 16]),
      TimeBucket(date: DateTime(2026, 11, 4), assetCount: 1, aspectRatios: [16 / 9]),
      TimeBucket(date: DateTime(2026, 11, 3), assetCount: 2, aspectRatios: [9 / 16, 9 / 16]),
    ];
    for (final immersive in [false, true]) {
      final segments = FixedSegmentBuilder(
        buckets: buckets,
        tileHeight: 128,
        columnCount: 3,
        denseLayout: true,
        hideDateHeaders: immersive,
        spacing: 3,
      ).generate().cast<FixedSegment>();
      expect(segments.map((s) => s.bucket), buckets);
      expect(segments.map((s) => s.firstAssetIndex), [0, 5, 6]);
      final first = segments.first;
      expect(first.rows.assetCountForRow(0), 3);
      expect(first.rows.assetCountForRow(1), 2);
      expect(segments[1].rows.assetCount, 1);
      // A scroll-to request for the lower small cell includes its intra-block
      // vertical position rather than landing on the preceding photograph.
      final lower = first.rows.cellsForRow(0)![1];
      expect(lower.top, greaterThan(0));
      expect(assetRowOffset(segment: first, assetIndexInTimeline: 1, columnCount: 3), first.gridOffset + lower.top);
      expect(assetRowOffset(segment: first, assetIndexInTimeline: 2, columnCount: 3), first.gridOffset);
    }
  });

  for (final removed in [1, 3]) {
    test('deleting $removed items in the middle of a long date leaves distant earlier cells in place', () {
      final source = List.generate(200, (i) => [16 / 9, 16 / 9, 9 / 16, 9 / 16, 9 / 16, 1.0, .75][i % 7]);
      final before = _layout(source);
      final after = _layout([...source.take(100), ...source.skip(100 + removed)]);
      Rect position(FixedRowLayout layout, int index) {
        final row = layout.rowForAssetIndex(index);
        return layout
            .cellsForRow(row)![index - layout.firstAssetIndexForRow(row)]
            .shift(Offset(0, layout.offsetForRow(row)));
      }

      for (var index = 0; index < 80; index++) {
        expect(
          position(after, index),
          position(before, index),
          reason: 'A distant deletion cannot rearrange an earlier viewport at asset $index',
        );
      }
    });
  }

  test('all adaptive cell geometry is immutable and reused for scroll/selection', () {
    final layout = _layout([16 / 9, 16 / 9, 9 / 16, 9 / 16, 9 / 16]);
    final cells = layout.cellsForRow(0)!;
    expect(() => cells[0] = Rect.zero, throwsUnsupportedError);
    for (var i = 0; i < 500; i++) {
      final row = layout.rowForOffset(i.toDouble());
      expect(layout.cellsForRow(row), same(layout.cellsForRow(row)));
      expect(layout.widthsForRow(row), same(layout.widthsForRow(row)));
    }
  });
}
