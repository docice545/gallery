import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/archive.action.dart';
import 'package:immich_mobile/presentation/actions/asset_debug.action.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/download.action.dart';
import 'package:immich_mobile/presentation/actions/edit_datetime.action.dart';
import 'package:immich_mobile/presentation/actions/edit_location.action.dart';
import 'package:immich_mobile/presentation/actions/favorite.action.dart';
import 'package:immich_mobile/presentation/actions/lock.action.dart';
import 'package:immich_mobile/presentation/actions/manage_stack.action.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_mobile/presentation/actions/share_link.action.dart';
import 'package:immich_mobile/presentation/actions/stack.action.dart';
import 'package:immich_mobile/presentation/actions/tag.action.dart';
import 'package:immich_mobile/presentation/actions/upload.action.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';
import 'package:immich_mobile/presentation/widgets/collection/collection_picker.widget.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';

class TimelineCompactSelection extends ConsumerWidget {
  const TimelineCompactSelection({super.key});

  static const _moreActions = <ActionBuilder>[
    AssetDebugAction(source: .timeline),
    ShareLinkAction(source: .timeline),
    DownloadAction(source: .timeline),
    FavoriteAction(source: .timeline),
    ArchiveAction(source: .timeline),
    TagAction(source: .timeline),
    EditDateTimeAction(source: .timeline),
    EditLocationAction(source: .timeline),
    LockAction(source: .timeline),
    StackAction(source: .timeline),
    ManageStackAction(source: .timeline),
    UploadAction(source: .timeline),
    DeleteEverywhereAction(source: .timeline),
    CleanupLocalAction(source: .timeline),
  ];

  Widget _actionButton(BuildContext context, WidgetRef ref, ActionBuilder builder, {bool destructive = false}) {
    var action = builder.create(context, ref);
    var kind = GhostTrashKind.server;
    if (action == null && destructive) {
      action = const CleanupLocalAction(source: .timeline).create(context, ref);
      kind = GhostTrashKind.device;
    }
    if (action == null) {
      return const SizedBox.shrink();
    }

    final button = IconButton(
      tooltip: action.label,
      icon: destructive
          ? FotoIcon(kind: FotoIconKind.trash, semanticLabel: action.label, state: FotoIconState.destructive)
          : Icon(action.icon),
      onPressed: action.onAction,
      onLongPress: action.onSecondaryAction,
    );

    return destructive ? GhostTrashTarget(kind: kind, child: button) : button;
  }

  Future<void> _showCollections(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 360, maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.42),
          child: CustomScrollView(
            shrinkWrap: true,
            slivers: [
              CollectionPicker(
                onCompleted: () {
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final extra = <Widget>[];

    for (final builder in _moreActions) {
      final action = builder.create(context, ref);
      if (action == null) {
        continue;
      }
      final tile = ListTile(
        dense: true,
        leading: Icon(action.icon),
        title: Text(action.label),
        onTap: action.onAction,
        onLongPress: action.onSecondaryAction,
      );
      extra.add(builder is CleanupLocalAction ? GhostTrashTarget(kind: GhostTrashKind.device, child: tile) : tile);
    }

    return CompactSelectionToolbar(
      deleteButton: _actionButton(context, ref, const DeleteAction(source: .timeline), destructive: true),
      shareButton: _actionButton(context, ref, const ShareAction(source: .timeline)),
      createButton: IconButton(
        tooltip: context.t.create,
        icon: const Icon(Icons.create_new_folder_outlined),
        onPressed: () => _showCollections(context),
      ),
      moreActions: extra,
    );
  }
}
