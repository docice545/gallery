import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/edit_asset.action.dart';
import 'package:immich_mobile/presentation/actions/google_lens.action.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/add_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/action_cell_grid.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/trash_action_bar.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/ocr.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/widgets/asset_viewer/video_controls.dart';

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
    final actions = <Widget>[];
    final labels = <String>[];
    void add(FotoIconKind kind, ActionBuilder builder, {String? caption}) {
      final item = builder.create(context, ref);
      if (item == null) {
        return;
      }
      final label = caption ?? fotoActionCaption(context, kind, item.label);
      labels.add(label);
      actions.add(
        SelectionToolbarAction(
          label: label,
          semanticLabel: item.label,
          kind: kind,
          onPressed: item.onAction,
          onLongPress: item.onSecondaryAction,
          destructive: kind == FotoIconKind.trash || kind == FotoIconKind.deviceTrash,
          trashKind: switch (kind) {
            FotoIconKind.trash => GhostTrashKind.server,
            FotoIconKind.deviceTrash => GhostTrashKind.device,
            _ => null,
          },
        ),
      );
    }

    if (!isReadonlyModeEnabled) {
      add(FotoIconKind.share, const ShareAction(source: .viewer));
      if (!isInLockedView) {
        add(FotoIconKind.edit, const EditAssetAction(source: .viewer));
        if (asset.hasRemote) {
          labels.add(context.t.add);
          actions.add(AddActionButton(originalTheme: originalTheme, iconOnly: true, labeled: true));
        }
        add(FotoIconKind.lens, GoogleLensAction(asset: asset, viewerContext: context));
        if (asset.storage == AssetState.local) {
          add(FotoIconKind.deviceTrash, const CleanupLocalAction(source: .viewer), caption: context.t.delete);
        } else {
          add(FotoIconKind.trash, const DeleteAction(source: .viewer));
        }
      }
    }
    // Normal viewer OCR stays in More; a readonly viewer retains its existing
    // OCR access without exposing the otherwise hidden modification menu.
    if (hasOcr && isReadonlyModeEnabled) {
      labels.add(context.t.ocr);
      actions.add(
        SelectionToolbarAction(
          label: context.t.ocr,
          kind: FotoIconKind.ocr,
          selected: ref.watch(assetViewerProvider.select((s) => s.showingOcr)),
          onPressed: ref.read(assetViewerProvider.notifier).toggleOcr,
        ),
      );
    }

    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : Durations.short4,
      child: showingDetails || (actions.isEmpty && !asset.isVideo)
          ? const SizedBox.shrink()
          : SelectionToolbarFrame(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (asset.isVideo) VideoControls(videoPlayerName: asset.id),
                  if (actions.isNotEmpty)
                    ActionCellGrid(
                      key: const ValueKey('viewer-action-row'),
                      compact: true,
                      labels: labels,
                      children: actions,
                    ),
                ],
              ),
            ),
    );
  }
}
