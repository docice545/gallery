import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/row_layout.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_scroll_target.dart';

void main() {
  FixedRowLayout layout(int count, {int columns = 3}) => FixedRowLayout(
    assetCount: count,
    columnCount: columns,
    tileHeight: (360 - 2 * (columns - 1)) / columns,
    spacing: 2,
    denseLayout: true,
  );

  test('one asset fills the row with bounded photo-first height', () {
    final rows = layout(1);
    expect(rows.rowCount, 1);
    expect(rows.heightForRow(0), 270);
    expect(FixedRowLayout.justifiedWidths(width: rows.width, spacing: 2, aspectRatios: [0.5]), [360]);
  });

  test('two assets share the full row without a trailing gap', () {
    final widths = FixedRowLayout.justifiedWidths(width: 360, spacing: 2, aspectRatios: [1, 1]);
    expect(widths, [179, 179]);
    expect(layout(2).heightForRow(0), 179);
  });

  test('rebalances an incomplete group instead of leaving a singleton after a full row', () {
    final rows = layout(5, columns: 4);
    expect([rows.assetCountForRow(0), rows.assetCountForRow(1)], [3, 2]);
    expect([rows.firstAssetIndexForRow(0), rows.firstAssetIndexForRow(1)], [0, 3]);
    expect(rows.rowForAssetIndex(3), 1);
    expect(rows.rowForAssetIndex(4), 1);
  });

  test('mixed portrait, landscape and malformed dimensions produce finite full-width rows', () {
    final widths = FixedRowLayout.justifiedWidths(
      width: 600,
      spacing: 2,
      aspectRatios: [0.2, 3, double.nan, double.infinity, 0],
    );
    expect(widths.every((width) => width.isFinite && width > 0), isTrue);
    expect(widths.reduce((a, b) => a + b) + 8, closeTo(600, 0.000001));
    expect(widths[1], greaterThan(widths[0]));
    expect(widths[2], widths[3]);
  });

  test('deterministic offsets and inverse row mappings cover every lazily loaded asset', () {
    for (var columns = 1; columns <= 5; columns++) {
      for (var count = 1; count <= 47; count++) {
        final rows = layout(count, columns: columns);
        var nextIndex = 0;
        for (var row = 0; row < rows.rowCount; row++) {
          expect(rows.firstAssetIndexForRow(row), nextIndex);
          final rowCount = rows.assetCountForRow(row);
          expect(rowCount, inInclusiveRange(1, columns));
          final offset = rows.offsetForRow(row);
          expect(rows.rowForOffset(offset), row);
          expect(rows.rowForOffset(offset + rows.heightForRow(row) / 2), row);
          for (var index = nextIndex; index < nextIndex + rowCount; index++) {
            expect(rows.rowForAssetIndex(index), row);
          }
          nextIndex += rowCount;
        }
        expect(nextIndex, count);
        expect(rows.extent, closeTo(rows.offsetForRow(rows.rowCount - 1) + rows.heightForRow(rows.rowCount - 1), 1e-8));
      }
    }
    expect(layout(0).extent, 0);
    expect(layout(0).rowCount, 0);
  });

  test('segment jumps, sliver offsets and headers use the rebalanced row geometry', () {
    final segments = FixedSegmentBuilder(
      buckets: [
        TimeBucket(date: DateTime(2026, 10, 4), assetCount: 5),
        TimeBucket(date: DateTime(2026, 10, 3), assetCount: 1),
      ],
      tileHeight: 88.5,
      columnCount: 4,
      spacing: 2,
      denseLayout: true,
    ).generate();
    final segment = segments.first as FixedSegment;
    final secondRowOffset = segment.gridOffset + segment.rows.offsetForRow(1);
    expect(assetRowOffset(segment: segment, assetIndexInTimeline: 3, columnCount: 4), secondRowOffset);
    expect(assetRowOffset(segment: segment, assetIndexInTimeline: 4, columnCount: 4), secondRowOffset);
    expect(segment.getMinChildIndexForScrollOffset(secondRowOffset), segment.gridIndex + 1);
    expect(segment.getMaxChildIndexForScrollOffset(secondRowOffset), segment.gridIndex);
    expect(segment.getMaxChildIndexForScrollOffset(secondRowOffset + 1), segment.gridIndex + 1);
    expect(segment.indexToLayoutOffset(segment.lastIndex + 1), segment.endOffset);
    expect(segment.endOffset, segments[1].startOffset);
    expect(segment.header, HeaderType.monthAndDay);
    expect(segments[1].header, HeaderType.day);
  });
}
