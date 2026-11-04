import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/scrubber_segments.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/place_names.provider.dart';
import 'package:intl/intl.dart';

/// Local synced metadata only. No asset fetch, GPS lookup or geocoder is used.
final timelineDateLocationProvider = FutureProvider.autoDispose.family<Place?, String>((ref, assetId) async {
  final db = ref.watch(driftProvider);
  final exif = await (db.select(db.remoteExifEntity)..where((row) => row.assetId.equals(assetId))).getSingleOrNull();
  return exif == null ? null : Place(name: exif.city ?? '', assetId: assetId, state: exif.state, country: exif.country);
});

String? timelinePlaceLabel(String? city, String? state, String? country) {
  for (final part in [city, state, country]) {
    if (part != null && part.trim().isNotEmpty) {
      return part.trim();
    }
  }
  return null;
}

/// Binary search over cached layout geometry; no scan of the photo library.
Segment? visibleTimelineDateSegment(List<Segment> segments, double offset) {
  if (segments.isEmpty || !offset.isFinite) {
    return null;
  }
  var low = 0;
  var high = segments.length;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    if (segments[middle].startOffset <= offset) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  final segment = segments[math.max(0, low - 1)];
  return segment.bucket is TimeBucket ? segment : null;
}

/// A widget that will display a BoxScrollView with a ScrollThumb that can be dragged
/// for quick navigation of the BoxScrollView.
class Scrubber extends ConsumerStatefulWidget {
  /// The view that will be scrolled with the scroll thumb
  final CustomScrollView child;

  /// The segments of the timeline
  final List<Segment> layoutSegments;

  final double timelineHeight;

  final double topPadding;

  final double bottomPadding;

  final double? monthSegmentSnappingOffset;

  final bool snapToMonth;

  final GroupAssetsBy groupBy;

  /// Whether an app bar is present, affects coordinate calculations
  final bool hasAppBar;
  final bool showFloatingDate;
  final BaseAsset? Function(int index)? assetAtIndex;
  final double Function()? contentStartOffset;

  Scrubber({
    super.key,
    required this.layoutSegments,
    required this.timelineHeight,
    this.topPadding = 0,
    this.bottomPadding = 0,
    this.monthSegmentSnappingOffset,
    this.snapToMonth = true,
    this.groupBy = GroupAssetsBy.day,
    this.hasAppBar = true,
    this.showFloatingDate = false,
    this.assetAtIndex,
    this.contentStartOffset,
    required this.child,
  }) : assert(child.scrollDirection == Axis.vertical);

  @override
  ConsumerState createState() => ScrubberState();
}

class ScrubberState extends ConsumerState<Scrubber> with TickerProviderStateMixin {
  String? _lastLabel;
  double _thumbTopOffset = 0.0;
  bool _isDragging = false;
  List<ScrubberSegment> _segments = [];
  int _snapSegmentCount = 0;

  late AnimationController _thumbAnimationController;
  Timer? _fadeOutTimer;
  Timer? _labelFadeTimer;
  late Animation<double> _thumbAnimation;

  late AnimationController _labelAnimationController;
  late Animation<double> _labelAnimation;

  double get _scrubberHeight => widget.timelineHeight - widget.topPadding - widget.bottomPadding;

  late ScrollController _scrollController;

  // A primary controller can briefly serve multiple scroll views during route
  // transitions. Its .position/.offset getters require exactly one attachment;
  // choosing an arbitrary one (or controller.jumpTo) could move another view.
  ScrollPosition? get _position {
    final position = _scrollController.positions.singleOrNull;
    if (position == null ||
        !position.hasPixels ||
        !position.hasContentDimensions ||
        !position.hasViewportDimension ||
        !position.pixels.isFinite ||
        !position.maxScrollExtent.isFinite ||
        !position.viewportDimension.isFinite) {
      return null;
    }
    return position;
  }

  double get _currentOffset {
    final position = _position;
    if (position == null) {
      return 0.0;
    }

    final maxExtent = position.maxScrollExtent;
    if (maxExtent <= 0 || !_scrubberHeight.isFinite || _scrubberHeight <= 0) {
      return 0.0;
    }
    return (position.pixels / maxExtent * _scrubberHeight).clamp(0.0, _scrubberHeight);
  }

  @override
  void initState() {
    super.initState();
    _isDragging = false;
    _segments = buildScrubberSegments(
      layoutSegments: widget.layoutSegments,
      timelineHeight: _scrubberHeight,
      groupBy: widget.groupBy,
    );
    _thumbAnimationController = AnimationController(vsync: this, duration: kTimelineScrubberFadeInDuration);
    _thumbAnimation = CurvedAnimation(parent: _thumbAnimationController, curve: Curves.fastEaseInToSlowEaseOut);
    _labelAnimationController = AnimationController(vsync: this, duration: kTimelineScrubberFadeInDuration);
    _snapSegmentCount = getSnapSegmentCount();

    _labelAnimation = CurvedAnimation(parent: _labelAnimationController, curve: Curves.fastOutSlowIn);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scrollController = PrimaryScrollController.of(context);
  }

  @override
  void didUpdateWidget(covariant Scrubber oldWidget) {
    super.didUpdateWidget(oldWidget);

    final oldScrubberHeight = oldWidget.timelineHeight - oldWidget.topPadding - oldWidget.bottomPadding;
    if (shouldRebuildScrubberSegments(
      oldLayoutSegments: oldWidget.layoutSegments,
      layoutSegments: widget.layoutSegments,
      oldGroupBy: oldWidget.groupBy,
      groupBy: widget.groupBy,
      oldScrubberHeight: oldScrubberHeight,
      scrubberHeight: _scrubberHeight,
    )) {
      _segments = buildScrubberSegments(
        layoutSegments: widget.layoutSegments,
        timelineHeight: _scrubberHeight,
        groupBy: widget.groupBy,
      );
      _snapSegmentCount = getSnapSegmentCount();
    }
  }

  @override
  void dispose() {
    _thumbAnimationController.dispose();
    _labelAnimationController.dispose();
    _fadeOutTimer?.cancel();
    _labelFadeTimer?.cancel();
    super.dispose();
  }

  void _resetThumbTimer() {
    _fadeOutTimer?.cancel();
    _fadeOutTimer = Timer(kTimelineScrubberFadeOutDuration, () {
      if (mounted) {
        unawaited(_thumbAnimationController.reverse());
      }
      _fadeOutTimer = null;
    });
  }

  void _scheduleLabelFade() {
    _labelFadeTimer?.cancel();
    _labelFadeTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!mounted || _isDragging) {
        return;
      }
      if (MediaQuery.disableAnimationsOf(context)) {
        _labelAnimationController.value = 0;
      } else {
        unawaited(_labelAnimationController.reverse());
      }
    });
  }

  ({String date, BaseAsset? asset})? _visibleDateLabel() {
    final position = _position;
    if (position == null) {
      return null;
    }
    final offset = position.pixels + widget.topPadding - (widget.contentStartOffset?.call() ?? 0);
    final segment = visibleTimelineDateSegment(widget.layoutSegments, offset);
    if (segment == null) {
      return null;
    }
    final date = (segment.bucket as TimeBucket).date;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final label = widget.groupBy == GroupAssetsBy.year
        ? DateFormat.y(locale).format(date)
        : widget.groupBy == GroupAssetsBy.month
        ? DateFormat.yMMMM(locale).format(date)
        : DateFormat.yMMMd(locale).format(date);
    var assetIndex = segment.firstAssetIndex;
    if (segment is FixedSegment && segment.rows.rowCount > 0) {
      final row = segment.rows.rowForOffset(offset - segment.gridOffset);
      assetIndex += segment.rows.firstAssetIndexForRow(row);
    }
    return (date: label, asset: widget.assetAtIndex?.call(assetIndex));
  }

  void _showLabel() {
    _labelFadeTimer?.cancel();
    if (!widget.showFloatingDate) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _labelAnimationController.value = 1;
    } else if (_labelAnimationController.status != AnimationStatus.forward && _labelAnimationController.value < 1) {
      unawaited(_labelAnimationController.forward());
    }
  }

  int getSnapSegmentCount() {
    return countScrubberSnapSegments(widget.layoutSegments, widget.groupBy);
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (_isDragging) {
      // If the user is dragging the thumb, we don't want to update the position
      return false;
    }

    if (notification is ScrollStartNotification || notification is ScrollUpdateNotification) {
      ref.read(timelineStateProvider.notifier).setScrolling(true);
    } else if (notification is ScrollEndNotification) {
      ref.read(timelineStateProvider.notifier).setScrolling(false);
    }

    setState(() {
      if (notification is ScrollStartNotification) {
        _showLabel();
      }
      if (notification is ScrollUpdateNotification) {
        _thumbTopOffset = _currentOffset;
        _showLabel();
        if (_thumbAnimationController.status != AnimationStatus.forward) {
          unawaited(_thumbAnimationController.forward());
        }
      }
      if (notification is ScrollEndNotification) {
        _scheduleLabelFade();
      }
      _resetThumbTimer();
    });

    return false;
  }

  void _onDragStart(DragStartDetails _) {
    if (_position == null) {
      return;
    }
    setState(() {
      _isDragging = true;
      _showLabel();
      _fadeOutTimer?.cancel();
      _lastLabel = null;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final position = _position;
    if (!_isDragging || position == null) {
      return;
    }

    if (_scrubberHeight <= 0) {
      return;
    }

    if (_thumbAnimationController.status != AnimationStatus.forward) {
      unawaited(_thumbAnimationController.forward());
    }

    final dragPosition = _calculateDragPosition(details);
    final nearestMonthSegment = _findNearestMonthSegment(dragPosition);

    if (nearestMonthSegment != null) {
      final label = nearestMonthSegment.scrollLabel;
      if (_lastLabel != label) {
        ref.read(hapticFeedbackProvider.notifier).selectionClick();
        _lastLabel = label;
      }
    }

    if (_snapSegmentCount < kMinMonthsToEnableScrubberSnap || !widget.snapToMonth) {
      // If there are less than kMinMonthsToEnableScrubberSnap months, we don't need to snap to segments
      setState(() {
        _thumbTopOffset = dragPosition;
        position.jumpTo((dragPosition / _scrubberHeight) * position.maxScrollExtent);
      });
    } else if (nearestMonthSegment != null) {
      _snapToSegment(nearestMonthSegment);
    }
  }

  /// Calculate the drag position relative to the scrubber area
  ///
  /// This method converts the global drag coordinates from the gesture detector
  /// into a position relative to the scrubber's active area (excluding padding).
  ///
  /// The scrubber has padding at the top and bottom, so we need to:
  /// 1. Calculate the actual draggable area (timelineHeight - topPadding - bottomPadding)
  /// 2. Convert the global Y position to a position within this draggable area
  /// 3. Clamp the result to ensure it stays within bounds (0 to dragAreaHeight)
  ///
  /// Example:
  /// - If timelineHeight = 800, topPadding = 50, bottomPadding = 50
  /// - Then dragAreaHeight = 700 (the actual scrubber area)
  /// - If user drags to global Y position that's 100 pixels from the top
  /// - The relative position would be 100 - 50 = 50 (50 pixels into the scrubber area)
  double _calculateDragPosition(DragUpdateDetails details) {
    if (widget.hasAppBar) {
      final dragAreaTop = widget.topPadding;
      final dragAreaBottom = widget.timelineHeight - widget.bottomPadding;
      final dragAreaHeight = dragAreaBottom - dragAreaTop;

      final relativePosition = details.globalPosition.dy - dragAreaTop;

      // Make sure the position stays within the scrubber's bounds
      return relativePosition.clamp(0.0, dragAreaHeight);
    }

    // Get the local position relative to the gesture detector
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox != null) {
      final localPosition = renderBox.globalToLocal(details.globalPosition);
      return localPosition.dy.clamp(0.0, _scrubberHeight);
    }

    // Fallback to current logic if render box is not available
    final dragAreaTop = widget.topPadding;
    final relativePosition = details.globalPosition.dy - dragAreaTop;
    return relativePosition.clamp(0.0, _scrubberHeight);
  }

  /// Find the segment closest to the given position
  ScrubberSegment? _findNearestMonthSegment(double position) {
    ScrubberSegment? nearestSegment;
    double minDistance = double.infinity;

    for (final segment in _segments) {
      final distance = (segment.startOffset - position).abs();
      if (distance < minDistance) {
        minDistance = distance;
        nearestSegment = segment;
      }
    }

    return nearestSegment;
  }

  /// Snap the scrubber thumb and scroll view to the given segment
  void _snapToSegment(ScrubberSegment segment) {
    setState(() {
      _thumbTopOffset = segment.startOffset;

      final layoutSegmentIndex = _findLayoutSegmentIndex(segment);

      if (layoutSegmentIndex >= 0) {
        _scrollToLayoutSegment(layoutSegmentIndex);
      }
    });
  }

  int _findLayoutSegmentIndex(ScrubberSegment segment) {
    return findScrubberLayoutSegmentIndex(widget.layoutSegments, segment, widget.groupBy);
  }

  void _scrollToLayoutSegment(int layoutSegmentIndex) {
    final position = _position;
    if (position == null) {
      return;
    }
    final layoutSegment = widget.layoutSegments[layoutSegmentIndex];
    final maxScrollExtent = position.maxScrollExtent;
    final viewportHeight = position.viewportDimension;

    final targetScrollOffset = layoutSegment.startOffset;
    final centeredOffset = targetScrollOffset - (viewportHeight / 4) + 100 + (widget.monthSegmentSnappingOffset ?? 0.0);

    position.jumpTo(centeredOffset.clamp(0.0, maxScrollExtent));
  }

  void _finishDrag() {
    _isDragging = false;
    _scheduleLabelFade();
    _resetThumbTimer();
  }

  void _onDragEnd(DragEndDetails _) => _onDragCancel();

  void _onDragCancel() {
    if (!_isDragging) {
      return;
    }
    setState(_finishDrag);
  }

  @override
  Widget build(BuildContext ctx) {
    final position = _position;
    if (_isDragging && (position == null || position.maxScrollExtent <= 0)) {
      // Removing an accepted drag's detector disposes its recognizer without
      // delivering onEnd/onCancel. End its bookkeeping in this rebuild so later
      // list scroll notifications are not mistaken for an active thumb drag.
      _finishDrag();
    }
    final label = widget.showFloatingDate ? _visibleDateLabel() : null;

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: Stack(
        children: [
          RepaintBoundary(child: widget.child),
          if (label != null)
            PositionedDirectional(
              top: math.max(widget.topPadding, MediaQuery.paddingOf(ctx).top) + 8,
              start: 12,
              end: kScrubberThumbHeight + 12,
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _labelAnimation,
                    builder: (context, _) => _labelAnimationController.isDismissed
                        ? const SizedBox.shrink()
                        : FadeTransition(
                            opacity: _labelAnimation,
                            child: Align(
                              alignment: AlignmentDirectional.topStart,
                              child: _FloatingDateLabel(date: label.date, asset: label.asset),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          // Scroll Segments - wrapped in RepaintBoundary for better performance
          RepaintBoundary(
            child: _SegmentsLayer(
              key: ValueKey('segments_${_isDragging}_${_segments.length}'),
              segments: _segments,
              topPadding: widget.topPadding,
              isDragging: _isDragging && position != null,
            ),
          ),
          if (position != null && position.maxScrollExtent > 0)
            PositionedDirectional(
              top: _thumbTopOffset + widget.topPadding,
              end: 0,
              child: RepaintBoundary(
                child: GestureDetector(
                  onVerticalDragStart: _onDragStart,
                  onVerticalDragUpdate: _onDragUpdate,
                  onVerticalDragEnd: _onDragEnd,
                  onVerticalDragCancel: _onDragCancel,
                  child: _Scrubber(thumbAnimation: _thumbAnimation),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SegmentsLayer extends StatelessWidget {
  final List<ScrubberSegment> segments;
  final double topPadding;
  final bool isDragging;

  const _SegmentsLayer({super.key, required this.segments, required this.topPadding, required this.isDragging});

  @override
  Widget build(BuildContext context) {
    return Visibility(
      visible: isDragging,
      child: Stack(
        children: segments
            .where((segment) => segment.showSegment)
            .map(
              (segment) => PositionedDirectional(
                key: ValueKey('segment_${segment.date.millisecondsSinceEpoch}'),
                top: topPadding + segment.startOffset,
                end: 100,
                child: RepaintBoundary(child: _SegmentWidget(segment)),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _SegmentWidget extends StatelessWidget {
  final ScrubberSegment _segment;

  const _SegmentWidget(this._segment);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.only(right: 36.0),
        child: Material(
          color: context.colorScheme.surface,
          borderRadius: const BorderRadius.all(Radius.circular(16.0)),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 28),
            padding: const EdgeInsets.symmetric(horizontal: 10.0),
            alignment: Alignment.center,
            child: Text(
              _segment.date.year.toString(),
              style: context.textTheme.labelMedium?.copyWith(fontFamily: "GoogleSansCode", fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingDateLabel extends ConsumerWidget {
  const _FloatingDateLabel({required this.date, this.asset});

  final String date;
  final BaseAsset? asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = asset;
    final embedded = current is RemoteAssetExif
        ? Place(
            name: current.exifInfo.city ?? '',
            assetId: current.id,
            state: current.exifInfo.state,
            country: current.exifInfo.country,
          )
        : null;
    final place =
        embedded ??
        (current?.remoteId == null ? null : ref.watch(timelineDateLocationProvider(current!.remoteId!)).valueOrNull);
    final location = place == null
        ? null
        : ref.watch(placeDisplayNamesProvider(Localizations.localeOf(context))).timelineLabel(place);
    return Material(
      key: const Key('timeline-floating-date'),
      color: Colors.black.withValues(alpha: .76),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              date,
              key: const Key('timeline-floating-date-text'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.labelMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            if (location != null)
              Text(
                location,
                key: const Key('timeline-floating-location-text'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.labelSmall?.copyWith(color: Colors.white),
              ),
          ],
        ),
      ),
    );
  }
}

class _Scrubber extends StatelessWidget {
  final Animation<double> thumbAnimation;

  const _Scrubber({required this.thumbAnimation});

  @override
  Widget build(BuildContext context) {
    final backgroundColor = context.isDarkTheme
        ? context.colorScheme.primary.darken(amount: .5)
        : context.colorScheme.primary;

    return _SlideFadeTransition(
      animation: thumbAnimation,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // The existing date label now lives at a fixed viewport position above.
          _CircularThumb(backgroundColor),
        ],
      ),
    );
  }
}

class _CircularThumb extends StatelessWidget {
  final Color backgroundColor;

  const _CircularThumb(this.backgroundColor);

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: const _ArrowPainter(Colors.white),
      child: Material(
        elevation: 4.0,
        color: backgroundColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(kScrubberThumbHeight),
          bottomLeft: Radius.circular(kScrubberThumbHeight),
          topRight: Radius.circular(4.0),
          bottomRight: Radius.circular(4.0),
        ),
        child: Container(
          constraints: BoxConstraints.tight(const Size(kScrubberThumbHeight * 0.6, kScrubberThumbHeight)),
        ),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final Color color;

  const _ArrowPainter(this.color);

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const width = 12.0;
    const height = 8.0;
    final baseX = size.width / 2;
    final baseY = size.height / 2;

    canvas.drawPath(_trianglePath(Offset(baseX, baseY - 2.0), width, height, true), paint);
    canvas.drawPath(_trianglePath(Offset(baseX, baseY + 2.0), width, height, false), paint);
  }

  static Path _trianglePath(Offset o, double width, double height, bool isUp) {
    return Path()
      ..moveTo(o.dx, o.dy)
      ..lineTo(o.dx + width, o.dy)
      ..lineTo(o.dx + (width / 2), isUp ? o.dy - height : o.dy + height)
      ..close();
  }
}

class _SlideFadeTransition extends StatelessWidget {
  final Animation<double> _animation;
  final Widget _child;

  const _SlideFadeTransition({required this._animation, required this._child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) => _animation.value == 0.0 ? const SizedBox() : child!,
      child: SlideTransition(
        position: Tween(begin: const Offset(0.3, 0.0), end: Offset.zero).animate(_animation),
        child: FadeTransition(opacity: _animation, child: _child),
      ),
    );
  }
}
