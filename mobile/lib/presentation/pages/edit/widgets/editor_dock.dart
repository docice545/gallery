import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One persistent row. Parameter content lives in the overlay, never in the
/// document's Column, so entering another tool cannot resize the photo.
class EditorDock extends StatefulWidget {
  const EditorDock({super.key, required this.controls, required this.onDismiss, this.popover, this.leading});

  final List<Widget> controls;
  final Widget? popover;
  final VoidCallback onDismiss;
  final Widget? leading;

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
      final available = top - safe.top - kToolbarHeight - 16;
      if (available < 48) {
        return const SizedBox.shrink();
      }
      return Positioned(
        left: safe.left + 12,
        right: safe.right + 12,
        bottom: overlay.size.height - top + 8,
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
                constraints: BoxConstraints(maxWidth: 360, maxHeight: math.min(160, available)),
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
      child: Material(
        key: const Key('editor-bottom-panel'),
        color: Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: .94),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        child: SafeArea(
          top: false,
          child: SizedBox(
            key: _dockKey,
            height: EditorDock.height,
            width: double.infinity,
            child: Row(
              key: const Key('editor-fixed-dock'),
              children: [
                if (widget.leading != null) widget.leading!,
                Expanded(
                  child: SingleChildScrollView(
                    key: const Key('editor-dock-scroll'),
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: Row(children: widget.controls),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
