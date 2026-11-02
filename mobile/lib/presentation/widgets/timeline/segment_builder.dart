import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/row.dart';
import 'package:immich_mobile/widgets/asset_grid/thumbnail_placeholder.dart';

abstract class SegmentBuilder {
  final List<Bucket> buckets;
  final double spacing;
  final GroupAssetsBy groupBy;

  const SegmentBuilder({required this.buckets, this.spacing = kTimelineSpacing, this.groupBy = GroupAssetsBy.day});

  static double headerExtent(HeaderType header, {bool compact = false, double textScale = 1.0}) => compact
      ? switch (header) {
          HeaderType.year || HeaderType.month => math.max(56, 32 * textScale + 16),
          HeaderType.day => math.max(48, 24 * textScale + 16),
          HeaderType.monthAndDay => math.max(48, 32 * textScale + 8) + math.max(48, 24 * textScale + 8) + 8,
          HeaderType.none => 0.0,
        }
      : switch (header) {
          HeaderType.year => kTimelineHeaderExtent,
          HeaderType.month => kTimelineHeaderExtent,
          HeaderType.day => kTimelineHeaderExtent * 0.90,
          HeaderType.monthAndDay => kTimelineHeaderExtent * 1.6,
          HeaderType.none => 0.0,
        };

  static Widget buildPlaceholder(
    BuildContext context,
    int count, {
    Size size = kTimelineFixedTileExtent,
    double spacing = kTimelineSpacing,
  }) => RepaintBoundary(
    child: TimelineRow.fixed(
      dimension: size.height,
      spacing: spacing,
      textDirection: Directionality.of(context),
      children: List.generate(count, (_) => ThumbnailPlaceholder(width: size.width, height: size.height)),
    ),
  );
}
