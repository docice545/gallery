import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// One persistent row. Parameter content lives in the overlay, never in the
/// document's Column, so entering another tool cannot resize the photo.
class EditorDock extends StatefulWidget {
  const EditorDock({
    super.key,
    required this.controls,
    required this.onDismiss,
    this.popover,
    this.leading,
    this.avoidPoint,
  });

  final List<Widget> controls;
  final Widget? popover;
  final VoidCallback onDismiss;
  final Widget? leading;

  /// Last photo interaction in global coordinates, read only when opening or
  /// laying out the transient controls. Pointer moves never rebuild the dock.
  final ValueGetter<Offset?>? avoidPoint;

  static const height = 56.0;

  @override
  State<EditorDock> createState() => _EditorDockState();
}

class _EditorDockState extends State<EditorDock> {
  final _portal = OverlayPortalController();
  final _dockKey = GlobalKey();

  @override
  void didUpdateWidget(covariant EditorDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.popover == null) != (widget.popover == null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        widget.popover == null ? _portal.hide() : _portal.show();
      });
    }
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: (context) {
      final dock = _dockKey.currentContext?.findRenderObject();
      final overlay = Overlay.of(context).context.findRenderObject();
      if (dock is! RenderBox || !dock.hasSize || overlay is! RenderBox || widget.popover == null) {
        return const SizedBox.shrink();
      }
      final top = dock.localToGlobal(Offset.zero, ancestor: overlay).dy;
      final safe = MediaQuery.paddingOf(context);
      final minimumTop = safe.top + kToolbarHeight + 8;
      final maximumBottom = top - 8;
      final available = maximumBottom - minimumTop;
      if (available < 48) {
        return const SizedBox.shrink();
      }
      var height = math.min(160.0, available);
      var bottom = maximumBottom;
      final globalPoint = widget.avoidPoint?.call();
      final point = globalPoint == null ? null : overlay.globalToLocal(globalPoint);
      // Keep a 32dp clear region around the working point. In short landscape
      // viewports use a smaller scrollable popover, never a taller dock.
      if (point != null && point.dy >= minimumTop && point.dy <= maximumBottom && point.dy > bottom - height - 32) {
        final above = point.dy - 32 - minimumTop;
        final below = maximumBottom - point.dy - 32;
        if (above >= 48 && above >= below) {
          height = math.min(height, above);
          bottom = point.dy - 32;
        } else if (below >= 48) {
          height = math.min(height, below);
        }
      }
      return Positioned(
        left: safe.left + 12,
        right: safe.right + 12,
        bottom: overlay.size.height - bottom,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: TapRegion(
            groupId: this,
            onTapOutside: (_) => widget.onDismiss(),
            child: Material(
              key: const Key('editor-parameter-popover'),
              color: Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: .96),
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 360, maxHeight: height),
                child: SingleChildScrollView(primary: false, child: widget.popover),
              ),
            ),
          ),
        ),
      );
    },
    child: TapRegion(
      groupId: this,
      onTapOutside: (_) => widget.onDismiss(),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.symmetric(horizontal: 14),
        child: Center(
          heightFactor: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: Material(
                key: const Key('editor-bottom-panel'),
                color: Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: .94),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .55)),
                ),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SizedBox(
                    key: _dockKey,
                    height: EditorDock.height,
                    child: Row(
                      key: const Key('editor-fixed-dock'),
                      children: [
                        if (widget.leading != null) widget.leading!,
                        Expanded(
                          child: SingleChildScrollView(
                            key: const Key('editor-dock-scroll'),
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            child: Row(children: widget.controls),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
