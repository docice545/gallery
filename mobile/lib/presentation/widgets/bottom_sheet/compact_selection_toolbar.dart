import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/action_cell_grid.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_ui/immich_ui.dart';

/// Compact floating selection toolbar.
///
/// The primary row never changes height when the overflow menu opens.
/// All action callbacks are supplied by the existing action system.
class CompactSelectionToolbar extends StatefulWidget {
  const CompactSelectionToolbar({super.key, required this.actions, required this.moreActions});

  final List<SelectionToolbarAction> actions;
  final List<Widget> moreActions;

  @override
  State<CompactSelectionToolbar> createState() => _CompactSelectionToolbarState();
}

class _CompactSelectionToolbarState extends State<CompactSelectionToolbar> {
  bool _showMore = false;

  @override
  Widget build(BuildContext context) {
    final actions = [
      ...widget.actions,
      if (widget.moreActions.isNotEmpty)
        SelectionToolbarAction(
          key: const ValueKey('selection-more-button'),
          kind: _showMore ? FotoIconKind.cancel : FotoIconKind.more,
          label: context.t.selection_more,
          semanticLabel: _showMore ? context.t.close : context.t.more,
          onPressed: () => setState(() => _showMore = !_showMore),
        ),
    ];
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
      child: ActionCellGrid(compact: true, labels: actions.map((action) => action.label).toList(), children: actions),
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
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (above != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: above),
            ViewerControlSurface(
              pill: true,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .45),
                child: SingleChildScrollView(child: child),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Shared labeled action used by viewer, selection, albums and trash.
/// The existing UI button retains async guarding and long-press behavior.
class SelectionToolbarAction extends StatelessWidget {
  const SelectionToolbarAction({
    super.key,
    required this.label,
    this.semanticLabel,
    this.kind,
    this.icon = Icons.more_horiz,
    required this.onPressed,
    this.onLongPress,
    this.destructive = false,
    this.selected = false,
    this.trashKind,
  });

  final String label;
  final String? semanticLabel;
  final FotoIconKind? kind;
  final IconData icon;
  final FutureOr<void> Function()? onPressed;
  final FutureOr<void> Function()? onLongPress;
  final bool destructive;
  final bool selected;
  final GhostTrashKind? trashKind;

  @override
  Widget build(BuildContext context) {
    final fullLabel = semanticLabel ?? label;
    final button = Tooltip(
      message: fullLabel,
      child: ImmichColumnButton(
        icon: icon,
        leadingIcon: kind == null
            ? Icon(icon, size: 22)
            : ExcludeSemantics(
                child: FotoIcon(
                  kind: kind!,
                  semanticLabel: fullLabel,
                  size: 22,
                  state: onPressed == null
                      ? FotoIconState.disabled
                      : destructive
                      ? FotoIconState.destructive
                      : selected
                      ? FotoIconState.active
                      : FotoIconState.normal,
                ),
              ),
        compact: true,
        label: label,
        semanticLabel: fullLabel,
        maxLabelWidth: double.infinity,
        maxLabelLines: null,
        preserveIconWhileLoading: destructive,
        foregroundColor: destructive ? Theme.of(context).colorScheme.error : null,
        disabled: onPressed == null,
        onPressed: onPressed ?? () {},
        onLongPress: onLongPress,
      ),
    );
    return trashKind == null ? button : GhostTrashTarget(kind: trashKind!, child: button);
  }
}

/// Short visual captions never replace the action's full accessible meaning.
String fotoActionCaption(BuildContext context, FotoIconKind? kind, String label) => switch (kind) {
  FotoIconKind.share => context.t.foto_action_send,
  FotoIconKind.edit => context.t.edit,
  FotoIconKind.addAlbum => context.t.add,
  FotoIconKind.link => context.t.link,
  FotoIconKind.lens => context.t.foto_action_lens,
  FotoIconKind.deviceTrash => context.t.foto_action_device_remove,
  FotoIconKind.trash => context.t.delete,
  _ => label,
};
