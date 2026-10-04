import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/row_layout.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment_builder.dart';

class FixedSegmentBuilder extends SegmentBuilder {
  final double tileHeight;
  final int columnCount;
  final bool denseLayout;

  const FixedSegmentBuilder({
    required super.buckets,
    required this.tileHeight,
    required this.columnCount,
    this.denseLayout = false,
    super.spacing,
    super.groupBy,
  });

  List<Segment> generate() {
    final segments = <Segment>[];
    int firstIndex = 0;
    double startOffset = 0;
    int assetIndex = 0;
    DateTime? previousDate;

    for (int i = 0; i < buckets.length; i++) {
      final bucket = buckets[i];

      final assetCount = bucket.assetCount;
      final rows = FixedRowLayout(
        assetCount: assetCount,
        columnCount: columnCount,
        tileHeight: tileHeight,
        spacing: spacing,
        denseLayout: denseLayout,
      );
      final numberOfRows = rows.rowCount;
      final segmentCount = numberOfRows + 1;

      final segmentFirstIndex = firstIndex;
      firstIndex += segmentCount;
      final segmentLastIndex = firstIndex - 1;

      final timelineHeader = switch (groupBy) {
        GroupAssetsBy.year => HeaderType.year,
        GroupAssetsBy.month => HeaderType.month,
        GroupAssetsBy.day || GroupAssetsBy.auto =>
          bucket is TimeBucket && bucket.date.month != previousDate?.month ? HeaderType.monthAndDay : HeaderType.day,
        GroupAssetsBy.none => HeaderType.none,
      };
      final headerExtent = SegmentBuilder.headerExtent(timelineHeader);

      final segmentStartOffset = startOffset;
      startOffset += headerExtent + rows.extent + (denseLayout && numberOfRows > 0 ? spacing : 0);
      final segmentEndOffset = startOffset;

      segments.add(
        FixedSegment(
          firstIndex: segmentFirstIndex,
          lastIndex: segmentLastIndex,
          startOffset: segmentStartOffset,
          endOffset: segmentEndOffset,
          firstAssetIndex: assetIndex,
          bucket: bucket,
          tileHeight: tileHeight,
          columnCount: columnCount,
          denseLayout: denseLayout,
          headerExtent: headerExtent,
          spacing: spacing,
          header: timelineHeader,
        ),
      );

      assetIndex += assetCount;
      if (bucket is TimeBucket) {
        previousDate = bucket.date;
      }
    }
    return segments;
  }
}
