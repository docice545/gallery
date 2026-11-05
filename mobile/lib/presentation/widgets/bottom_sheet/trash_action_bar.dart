import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/restore.action.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/action_cell_grid.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';

/// The same two actions and geometry in trash selection and the trash viewer.
/// Actions retain their existing owner checks and irreversible-delete dialog.
class TrashActionBar extends ConsumerStatefulWidget {
  const TrashActionBar({super.key, required this.source});
  final ActionSource source;

  @override
  ConsumerState<TrashActionBar> createState() => _TrashActionBarState();
}

class _TrashActionBarState extends ConsumerState<TrashActionBar> {
  bool _running = false;

  Future<void> _run(ActionItem action) async {
    if (_running) {
      return;
    }
    setState(() => _running = true);
    try {
      await action.onAction();
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(readonlyModeProvider)) {
      return const SizedBox.shrink();
    }
    final restore = RestoreAction(source: widget.source).create(context, ref);
    final delete = DeleteAction(source: widget.source).create(context, ref);
    final labels = [context.t.restore, context.t.delete_permanently];
    final actions = [restore, delete];
    return SelectionToolbarFrame(
      child: ActionCellGrid(
        compact: true,
        labels: labels,
        children: [
          for (var index = 0; index < actions.length; index++)
            SelectionToolbarAction(
              key: ValueKey(index == 0 ? 'trash-restore' : 'trash-delete-permanently'),
              label: labels[index],
              kind: index == 0 ? FotoIconKind.restore : FotoIconKind.trash,
              destructive: index == 1,
              onPressed: actions[index] != null && !_running ? () => _run(actions[index]!) : null,
            ),
        ],
      ),
    );
  }
}
