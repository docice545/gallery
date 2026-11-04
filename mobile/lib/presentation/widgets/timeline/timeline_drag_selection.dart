import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_drag_region.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

/// Listens to long hold drags on a timeline [ScrollView] and handles multi-select scenarios with automated scrolling
class TimelineDragSelection extends ConsumerStatefulWidget {
  const TimelineDragSelection({super.key, required this.builder});

  final Widget Function(ScrollPhysics? physics) builder;

  @override
  ConsumerState createState() => _TimelineDragSelectionState();
}

class _TimelineDragSelectionState extends ConsumerState<TimelineDragSelection> {
  bool _dragging = false;
  TimelineAssetIndex? _dragAnchorIndex;
  Set<AssetSelectionKey> _baseline = {};
  AssetSelectionKey? _anchorId;
  TimelineService? _dragTimeline;
  StreamSubscription<TimelineReloadEvent>? _reloadSubscription;
  ScrollPhysics? _scrollPhysics;

  @override
  void initState() {
    super.initState();
    _reloadSubscription = EventStream.shared.listen<TimelineReloadEvent>((_) {
      if (mounted) {
        _stopDrag();
      }
    });
  }

  @override
  void dispose() {
    unawaited(_reloadSubscription?.cancel());
    super.dispose();
  }

  void _setDragStartIndex(TimelineAssetIndex index) {
    final timeline = ref.read(timelineServiceProvider);
    final asset = timeline.getAssetSafe(index.assetIndex);
    final selection = ref.read(multiSelectProvider);
    if (asset == null || selection.isLocked(asset)) {
      return;
    }
    _baseline = selection.selectedIds.toSet();
    _anchorId = assetSelectionKey(asset);
    _dragTimeline = timeline;
    ref.read(multiSelectProvider.notifier).selectAsset(asset);
    ref.read(hapticFeedbackProvider.notifier).heavyImpact();
    setState(() {
      _scrollPhysics = const ClampingScrollPhysics();
      _dragAnchorIndex = index;
      _dragging = true;
    });
  }

  void _stopDrag() {
    if (!_dragging) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Update the physics post frame to prevent sudden change in physics on iOS.
      if (mounted && !_dragging) {
        setState(() => _scrollPhysics = null);
      }
    });
    setState(() {
      _dragging = false;
      _dragAnchorIndex = null;
      _anchorId = null;
      _dragTimeline = null;
      _baseline = {};
    });
    ref.read(timelineStateProvider.notifier).setScrolling(false);
  }

  Future<void> _dragScroll(ScrollDirection direction) {
    final scrollController = PrimaryScrollController.of(context);
    final position = scrollController.positions.singleOrNull;
    if (!_dragging || position == null) {
      return Future.value();
    }
    return position.animateTo(
      position.pixels + (direction == ScrollDirection.forward ? 175 : -175),
      duration: const Duration(milliseconds: 125),
      curve: Curves.easeOut,
    );
  }

  void _handleDragAssetEnter(TimelineAssetIndex index) {
    if (_dragAnchorIndex == null || !_dragging) {
      return;
    }

    final timelineService = ref.read(timelineServiceProvider);
    final dragAnchorIndex = _dragAnchorIndex!;

    final anchor = timelineService.getAssetSafe(dragAnchorIndex.assetIndex);
    if (!identical(timelineService, _dragTimeline) || anchor == null || assetSelectionKey(anchor) != _anchorId) {
      _stopDrag();
      return;
    }

    final startIndex = math.min(dragAnchorIndex.assetIndex, index.assetIndex);
    final endIndex = math.max(dragAnchorIndex.assetIndex, index.assetIndex);
    final count = endIndex - startIndex + 1;
    if (timelineService.hasRange(startIndex, count)) {
      ref
          .read(multiSelectProvider.notifier)
          .updateDragSelection(_baseline, timelineService.getAssets(startIndex, count));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isReadonlyModeEnabled = ref.watch(readonlyModeProvider);

    return TimelineDragRegion(
      onStart: !isReadonlyModeEnabled ? _setDragStartIndex : null,
      onAssetEnter: _handleDragAssetEnter,
      onEnd: !isReadonlyModeEnabled ? _stopDrag : null,
      onScroll: (direction) => unawaited(_dragScroll(direction)),
      onScrollStart: () {
        // Minimize the bottom sheet when drag selection starts
        if (_dragging) {
          ref.read(timelineStateProvider.notifier).setScrolling(true);
        }
      },
      child: widget.builder(_scrollPhysics),
    );
  }
}
