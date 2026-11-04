import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';

/// One measured capsule; overflow lives outside the document layout.
class CompactSelectionToolbar extends StatefulWidget {
  const CompactSelectionToolbar({
    super.key,
    required this.deleteButton,
    required this.shareButton,
    required this.createButton,
    required this.moreActions,
  });
  final Widget deleteButton;
  final Widget shareButton;
  final Widget createButton;
  final List<Widget> moreActions;
  @override
  State<CompactSelectionToolbar> createState() => _CompactSelectionToolbarState();
}

class _CompactSelectionToolbarState extends State<CompactSelectionToolbar> {
  final _portal = OverlayPortalController();
  final _anchor = GlobalKey();
  bool _showMore = false;

  void _toggle() {
    setState(() => _showMore = !_showMore);
    _showMore ? _portal.show() : _portal.hide();
  }

  Widget _labeledAction(Widget button, String label) => Column(
    mainAxisSize: MainAxisSize.min,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      SizedBox(height: 48, child: Center(child: button)),
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurface, fontSize: 11),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: (context) {
      final box = _anchor.currentContext?.findRenderObject();
      final overlay = Overlay.of(context).context.findRenderObject();
      if (box is! RenderBox || overlay is! RenderBox) {
        return const SizedBox.shrink();
      }
      final top = box.localToGlobal(Offset.zero, ancestor: overlay).dy;
      final available = math.max(0.0, top - MediaQuery.paddingOf(context).top - 16);
      return Positioned(
        right: MediaQuery.paddingOf(context).right + 12,
        bottom: overlay.size.height - top + 8,
        child: TapRegion(
          groupId: this,
          onTapOutside: (_) {
            if (_showMore) {
              _toggle();
            }
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.min(260, overlay.size.width - 24),
              maxHeight: math.min(available, overlay.size.height * .45),
            ),
            child: ViewerControlSurface(
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: widget.moreActions),
              ),
            ),
          ),
        ),
      );
    },
    child: TapRegion(
      groupId: this,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 392),
              child: ViewerControlSurface(
                child: SizedBox(
                  key: _anchor,
                  height: math.max(64, 50 + MediaQuery.textScalerOf(context).scale(11)),
                  child: Row(
                    children: [
                      Expanded(child: _labeledAction(widget.deleteButton, context.t.delete)),
                      Expanded(child: _labeledAction(widget.shareButton, context.t.share)),
                      Expanded(child: _labeledAction(widget.createButton, context.t.add)),
                      Expanded(
                        child: _labeledAction(
                          IconButton(
                            key: const ValueKey('selection-more-button'),
                            tooltip: _showMore ? context.t.close : context.t.more,
                            icon: Icon(_showMore ? Icons.close : Icons.more_horiz),
                            onPressed: widget.moreActions.isEmpty ? null : _toggle,
                          ),
                          context.t.more,
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
  );
}
