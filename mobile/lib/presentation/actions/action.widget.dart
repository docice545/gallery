import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/action_cell_grid.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_ui/immich_ui.dart';

abstract class ActionWidget extends ConsumerWidget {
  final ActionBuilder action;

  const ActionWidget({super.key, required this.action});

  Widget builder(BuildContext context, WidgetRef ref, ActionItem action);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actionItem = action.create(context, ref);
    if (actionItem == null) {
      return const SizedBox.shrink();
    }

    return builder(context, ref, actionItem);
  }
}

class ActionColumnButton extends ActionWidget {
  const ActionColumnButton({super.key, required super.action, this.fotoKind});

  final FotoIconKind? fotoKind;

  @override
  Widget builder(BuildContext context, WidgetRef ref, ActionItem action) => _ghostTarget(
    ActionCellGrid.isCompact(context)
        ? SelectionToolbarAction(
            label: fotoActionCaption(context, fotoKind, action.label),
            semanticLabel: action.label,
            kind: switch ((fotoKind, action.icon)) {
              (FotoIconKind.archive, Icons.unarchive_outlined) => FotoIconKind.unarchive,
              (FotoIconKind.lock, Icons.lock_open_rounded) => FotoIconKind.unlock,
              (FotoIconKind.stack, Icons.layers_clear_outlined) => FotoIconKind.unstack,
              _ => fotoKind,
            },
            selected: fotoKind == FotoIconKind.favorite && action.icon == Icons.favorite_rounded,
            icon: action.icon,
            destructive: fotoKind == FotoIconKind.trash || fotoKind == FotoIconKind.deviceTrash,
            onPressed: action.onAction,
            onLongPress: action.onSecondaryAction,
          )
        : ImmichColumnButton(
            icon: action.icon,
            compact: ActionCellGrid.isCompact(context),
            preserveIconWhileLoading: fotoKind == FotoIconKind.trash || fotoKind == FotoIconKind.deviceTrash,
            maxLabelWidth: ActionCellGrid.contains(context) ? double.infinity : 90,
            maxLabelLines: ActionCellGrid.contains(context) ? null : 2,
            leadingIcon: fotoKind == null
                ? null
                : ExcludeSemantics(
                    child: FotoIcon(
                      kind: switch ((fotoKind!, action.icon)) {
                        (FotoIconKind.archive, Icons.unarchive_outlined) => FotoIconKind.unarchive,
                        (FotoIconKind.lock, Icons.lock_open_rounded) => FotoIconKind.unlock,
                        (FotoIconKind.stack, Icons.layers_clear_outlined) => FotoIconKind.unstack,
                        _ => fotoKind!,
                      },
                      semanticLabel: action.label,
                      size: 24,
                      state: fotoKind == FotoIconKind.trash || fotoKind == FotoIconKind.deviceTrash
                          ? FotoIconState.destructive
                          : fotoKind == FotoIconKind.favorite && action.icon == Icons.favorite_rounded
                          ? FotoIconState.active
                          : FotoIconState.normal,
                    ),
                  ),
            label: action.label,
            onPressed: action.onAction,
            onLongPress: action.onSecondaryAction,
          ),
  );

  Widget _ghostTarget(Widget child) => switch (fotoKind) {
    FotoIconKind.trash => GhostTrashTarget(kind: GhostTrashKind.server, child: child),
    FotoIconKind.deviceTrash => GhostTrashTarget(kind: GhostTrashKind.device, child: child),
    _ => child,
  };
}

class ActionIconButton extends ActionWidget {
  final ImmichVariant variant;

  const ActionIconButton({super.key, required super.action, this.variant = .ghost});

  @override
  Widget builder(BuildContext context, WidgetRef ref, ActionItem action) => ImmichIconButton(
    icon: action.icon,
    onPressed: action.onAction,
    onLongPress: action.onSecondaryAction,
    variant: variant,
  );
}

class ActionButton extends ActionWidget {
  final ImmichVariant variant;

  const ActionButton({super.key, required super.action, this.variant = .ghost});

  @override
  Widget builder(BuildContext context, WidgetRef ref, ActionItem action) => ImmichTextButton(
    labelText: action.label,
    icon: action.icon,
    onPressed: action.onAction,
    onLongPress: action.onSecondaryAction,
    variant: variant,
  );
}

class ActionMenuItem extends ActionWidget {
  const ActionMenuItem({super.key, required super.action, this.fotoKind});

  final FotoIconKind? fotoKind;

  @override
  Widget builder(BuildContext context, WidgetRef ref, ActionItem action) => ImmichMenuItem(
    icon: action.icon,
    leadingIcon: fotoKind == null
        ? null
        : ExcludeSemantics(
            child: FotoIcon(
              kind: fotoKind!,
              semanticLabel: action.label,
              size: 20,
              state: fotoKind == FotoIconKind.trash || fotoKind == FotoIconKind.deviceTrash
                  ? FotoIconState.destructive
                  : FotoIconState.normal,
            ),
          ),
    label: action.label,
    onPressed: action.onAction,
  );
}
