import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';

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

  Widget _labeledAction(Widget button, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
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
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurface, fontSize: 11),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
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
              if (_showMore && widget.moreActions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 260, maxHeight: MediaQuery.sizeOf(context).height * 0.45),
                    child: ViewerControlSurface(
                      child: SingleChildScrollView(
                        child: Column(mainAxisSize: MainAxisSize.min, children: widget.moreActions),
                      ),
                    ),
                  ),
                ),
              ViewerControlSurface(
                child: SizedBox(
                  height: 76 + (MediaQuery.textScalerOf(context).scale(11) - 11).clamp(0, double.infinity),
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
                            onPressed: widget.moreActions.isEmpty ? null : () => setState(() => _showMore = !_showMore),
                          ),
                          context.t.more,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
