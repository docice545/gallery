import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/edit_asset.action.dart';
import 'package:immich_mobile/presentation/actions/restore.action.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_mobile/presentation/actions/upload.action.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/add_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/ocr_toggle_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/trash_action_bar.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/ocr.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/widgets/asset_viewer/video_controls.dart';

// Resolve enablement with the existing actions; hidden actions take no slot.
List<Widget> _actions(BuildContext context, WidgetRef ref, List<(FotoIconKind, ActionBuilder)> actions) => [
  for (final (kind, builder) in actions)
    if (builder.create(context, ref) case final item?)
      _ghostTarget(
        kind,
        FotoIconButton(
          kind: kind,
          label: item.label,
          onPressed: item.onAction,
          onLongPress: item.onSecondaryAction,
          destructive: kind == FotoIconKind.trash || kind == FotoIconKind.deviceTrash,
        ),
      ),
];

Widget _ghostTarget(FotoIconKind kind, Widget child) => switch (kind) {
  FotoIconKind.trash => GhostTrashTarget(kind: GhostTrashKind.server, child: child),
  FotoIconKind.deviceTrash => GhostTrashTarget(kind: GhostTrashKind.device, child: child),
  _ => child,
};

class ViewerBottomBar extends ConsumerWidget {
  const ViewerBottomBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetViewerProvider.select((s) => s.currentAsset));
    if (asset == null) {
      return const SizedBox.shrink();
    }

    final isReadonlyModeEnabled = ref.watch(readonlyModeProvider);
    final showingDetails = ref.watch(assetViewerProvider.select((s) => s.showingDetails));
    final isInLockedView = ref.watch(inLockedViewProvider);
    final isInTrash = ref.watch(timelineServiceProvider).origin == TimelineOrigin.trash;

    if (isInTrash) {
      return showingDetails ? const SizedBox.shrink() : const TrashActionBar(source: .viewer);
    }

    final originalTheme = context.themeData;

    final hasOcr =
        asset is RemoteAsset && asset.isImage && ref.watch(ocrAssetProvider(asset.id)).valueOrNull?.isNotEmpty == true;
    final actions = <Widget>[
      if (!isReadonlyModeEnabled) ...[
        ..._actions(context, ref, const [
          (FotoIconKind.restore, RestoreAction(source: .viewer)),
          (FotoIconKind.share, ShareAction(source: .viewer)),
        ]),
        if (!isInLockedView) ...[
          if (!isInTrash) ...[
            ..._actions(context, ref, const [
              (FotoIconKind.upload, UploadAction(source: .viewer, showProgress: true)),
              (FotoIconKind.edit, EditAssetAction(source: .viewer)),
            ]),
            if (asset.hasRemote) AddActionButton(originalTheme: originalTheme, iconOnly: true),
          ],
          ..._actions(context, ref, [
            if (asset.storage == AssetState.local)
              (FotoIconKind.deviceTrash, const CleanupLocalAction(source: .viewer))
            else
              (FotoIconKind.trash, const DeleteAction(source: .viewer)),
          ]),
        ],
      ],
      if (hasOcr) OcrToggleButton(asset: asset),
    ];

    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : Durations.short4,
      child: showingDetails
          ? const SizedBox.shrink()
          : SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 448),
                  child: ViewerControlSurface(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (asset.isVideo) VideoControls(videoPlayerName: asset.id),
                        if (actions.isNotEmpty)
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final row = SizedBox(
                                key: const ValueKey('viewer-action-row'),
                                height: 56,
                                width: constraints.maxWidth < actions.length * 48
                                    ? actions.length * 48.0
                                    : constraints.maxWidth,
                                child: Row(
                                  children: [for (final action in actions) Expanded(child: Center(child: action))],
                                ),
                              );
                              return constraints.maxWidth < actions.length * 48
                                  ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: row)
                                  : row;
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
