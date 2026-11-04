import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'timeline_drag_region.freezed.dart';

class TimelineDragRegion extends StatefulWidget {
  final Widget child;

  final void Function(TimelineAssetIndex valueKey)? onStart;
  final void Function(TimelineAssetIndex valueKey)? onAssetEnter;
  final void Function()? onEnd;
  final void Function()? onScrollStart;
  final void Function(ScrollDirection direction)? onScroll;

  const TimelineDragRegion({
    super.key,
    required this.child,
    this.onStart,
    this.onAssetEnter,
    this.onEnd,
    this.onScrollStart,
    this.onScroll,
  });

  @override
  State createState() => _TimelineDragRegionState();
}

class _TimelineDragRegionState extends State<TimelineDragRegion> {
  late TimelineAssetIndex? assetUnderPointer;
  late TimelineAssetIndex? anchorAsset;

  // Scroll related state
  static const double scrollOffset = 0.10;
  double? topScrollOffset;
  double? bottomScrollOffset;
  Timer? scrollTimer;
  late bool scrollNotified;
  final Set<int> _pointers = {};

  @override
  void initState() {
    super.initState();
    assetUnderPointer = null;
    anchorAsset = null;
    scrollNotified = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    topScrollOffset = null;
    bottomScrollOffset = null;
  }

  @override
  void dispose() {
    scrollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        _pointers.add(event.pointer);
        if (_pointers.length > 1) {
          _onLongPressEnd();
        }
      },
      onPointerUp: (event) => _pointers.remove(event.pointer),
      onPointerCancel: (event) {
        _pointers.remove(event.pointer);
        _onLongPressEnd();
      },
      child: RawGestureDetector(
        gestures: {
          if (widget.onStart != null)
            LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              LongPressGestureRecognizer.new,
              _registerCallbacks,
            ),
        },
        child: widget.child,
      ),
    );
  }

  void _registerCallbacks(LongPressGestureRecognizer recognizer) {
    recognizer.onLongPressMoveUpdate = (details) => _onLongPressMove(details);
    recognizer.onLongPressStart = (details) => _onLongPressStart(details);
    recognizer.onLongPressUp = _onLongPressEnd;
    recognizer.onLongPressCancel = _onLongPressEnd;
  }

  TimelineAssetIndex? _getValueKeyAtPosition(Offset position) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) {
      return null;
    }

    final hitTestResult = BoxHitTestResult();
    final local = box.globalToLocal(position);
    if (!box.hitTest(hitTestResult, position: local)) {
      return null;
    }

    return (hitTestResult.path.firstWhereOrNull((hit) => hit.target is _TimelineAssetIndexProxy)?.target
            as _TimelineAssetIndexProxy?)
        ?.index;
  }

  void _onLongPressStart(LongPressStartDetails event) {
    if (_pointers.length != 1) {
      return;
    }

    /// Calculate widget height and scroll offset when long press starting instead of in [initState]
    /// or [didChangeDependencies] as the grid might still be rendering into view to get the actual size
    final height = context.size?.height;
    if (height != null && (topScrollOffset == null || bottomScrollOffset == null)) {
      topScrollOffset = height * scrollOffset;
      bottomScrollOffset = height - topScrollOffset!;
    }

    final initialHit = _getValueKeyAtPosition(event.globalPosition);
    anchorAsset = initialHit;
    assetUnderPointer = initialHit;
    if (initialHit == null) {
      return;
    }

    if (anchorAsset != null) {
      widget.onStart?.call(anchorAsset!);
    }
  }

  void _onLongPressEnd() {
    final wasActive = anchorAsset != null;
    anchorAsset = null;
    assetUnderPointer = null;
    scrollNotified = false;
    scrollTimer?.cancel();
    scrollTimer = null;
    if (wasActive) {
      widget.onEnd?.call();
    }
  }

  void _onLongPressMove(LongPressMoveUpdateDetails event) {
    if (anchorAsset == null) {
      return;
    }
    if (topScrollOffset == null || bottomScrollOffset == null) {
      return;
    }

    final currentDy = event.localPosition.dy;

    if (currentDy > bottomScrollOffset!) {
      scrollTimer ??= Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => widget.onScroll?.call(ScrollDirection.forward),
      );
    } else if (currentDy < topScrollOffset!) {
      scrollTimer ??= Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => widget.onScroll?.call(ScrollDirection.reverse),
      );
    } else {
      scrollTimer?.cancel();
      scrollTimer = null;
    }

    final currentlyTouchingAsset = _getValueKeyAtPosition(event.globalPosition);
    if (currentlyTouchingAsset == null) {
      return;
    }

    if (assetUnderPointer != currentlyTouchingAsset) {
      if (!scrollNotified) {
        scrollNotified = true;
        widget.onScrollStart?.call();
      }

      widget.onAssetEnter?.call(currentlyTouchingAsset);
      assetUnderPointer = currentlyTouchingAsset;
    }
  }
}

class TimelineAssetIndexWrapper extends SingleChildRenderObjectWidget {
  final int assetIndex;
  final int segmentIndex;

  const TimelineAssetIndexWrapper({
    required Widget super.child,
    required this.assetIndex,
    required this.segmentIndex,
    super.key,
  });

  @override
  // ignore: library_private_types_in_public_api
  _TimelineAssetIndexProxy createRenderObject(BuildContext context) {
    return _TimelineAssetIndexProxy(
      index: TimelineAssetIndex(assetIndex: assetIndex, segmentIndex: segmentIndex),
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    // ignore: library_private_types_in_public_api
    _TimelineAssetIndexProxy renderObject,
  ) {
    renderObject.index = TimelineAssetIndex(assetIndex: assetIndex, segmentIndex: segmentIndex);
  }
}

class _TimelineAssetIndexProxy extends RenderProxyBox {
  TimelineAssetIndex index;

  _TimelineAssetIndexProxy({required this.index});
}

@freezed
abstract class TimelineAssetIndex with _$TimelineAssetIndex {
  const factory TimelineAssetIndex({required int assetIndex, required int segmentIndex}) = _TimelineAssetIndex;
}
