import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/action_cell_grid.dart';

/// Compact floating selection toolbar.
///
/// The primary row never changes height when the overflow menu opens.
/// All action callbacks are supplied by the existing action system.
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
  bool _showMore = false;

  @override
  Widget build(BuildContext context) {
    return SelectionToolbarFrame(
      above: _showMore && widget.moreActions.isNotEmpty
          ? ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 260, maxHeight: MediaQuery.sizeOf(context).height * .45),
              child: ViewerControlSurface(
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: widget.moreActions),
                ),
              ),
            )
          : null,
      child: ActionCellGrid(
        compact: true,
        children: [
          SelectionToolbarAction(button: widget.deleteButton, label: context.t.delete),
          SelectionToolbarAction(button: widget.shareButton, label: context.t.share),
          SelectionToolbarAction(button: widget.createButton, label: context.t.add),
          SelectionToolbarAction(
            button: IconButton(
              key: const ValueKey('selection-more-button'),
              tooltip: _showMore ? context.t.close : context.t.more,
              icon: Icon(_showMore ? Icons.close : Icons.more_horiz),
              onPressed: widget.moreActions.isEmpty ? null : () => setState(() => _showMore = !_showMore),
            ),
            label: context.t.selection_more,
          ),
        ],
      ),
    );
  }
}

/// Shared floating surface for Timeline, Albums and Library selection actions.
/// Height follows content; only oversized accessibility content scrolls.
class SelectionToolbarFrame extends StatelessWidget {
  const SelectionToolbarFrame({super.key, required this.child, this.above});
  final Widget child;
  final Widget? above;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    minimum: const EdgeInsets.fromLTRB(12, 4, 12, 8),
    child: Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 392),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (above != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: above),
            ViewerControlSurface(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .45),
                child: SingleChildScrollView(
                  child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: child),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SelectionToolbarAction extends StatelessWidget {
  const SelectionToolbarAction({super.key, required this.button, required this.label});
  final Widget button;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox.square(
        dimension: 48,
        child: IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(fixedSize: const Size.square(48), visualDensity: VisualDensity.standard),
          ),
          child: button,
        ),
      ),
      Text(
        label,
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurface, fontSize: 11),
      ),
    ],
  );
}
