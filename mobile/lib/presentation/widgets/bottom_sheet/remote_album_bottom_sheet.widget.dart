import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/archive.action.dart';
import 'package:immich_mobile/presentation/actions/asset_debug.action.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/download.action.dart';
import 'package:immich_mobile/presentation/actions/edit_datetime.action.dart';
import 'package:immich_mobile/presentation/actions/edit_location.action.dart';
import 'package:immich_mobile/presentation/actions/favorite.action.dart';
import 'package:immich_mobile/presentation/actions/lock.action.dart';
import 'package:immich_mobile/presentation/actions/manage_stack.action.dart';
import 'package:immich_mobile/presentation/actions/remove_from_album.action.dart';
import 'package:immich_mobile/presentation/actions/set_album_cover.action.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_mobile/presentation/actions/share_link.action.dart';
import 'package:immich_mobile/presentation/actions/stack.action.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/base_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/collection/collection_picker.widget.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/user.provider.dart';

class RemoteAlbumBottomSheet extends ConsumerStatefulWidget {
  final RemoteAlbum album;
  const RemoteAlbumBottomSheet({super.key, required this.album});

  @override
  ConsumerState<RemoteAlbumBottomSheet> createState() => _RemoteAlbumBottomSheetState();
}

class _RemoteAlbumBottomSheetState extends ConsumerState<RemoteAlbumBottomSheet> {
  late DraggableScrollableController sheetController;

  @override
  void initState() {
    super.initState();
    sheetController = DraggableScrollableController();
  }

  @override
  void dispose() {
    sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ownsAlbum = ref.watch(currentUserProvider)?.id == widget.album.ownerId;

    Future<void> onKeyboardExpand() {
      return sheetController.animateTo(0.85, duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
    }

    return BaseBottomSheet(
      controller: sheetController,
      initialChildSize: 0.22,
      minChildSize: 0.22,
      maxChildSize: 0.85,
      shouldCloseOnMinExtent: false,
      actions: <ActionColumnButton>[
        const .new(
          fotoKind: FotoIconKind.trash,
          action: DeleteAction(source: .timeline),
        ),
        const .new(
          fotoKind: FotoIconKind.debug,
          action: AssetDebugAction(source: .timeline),
        ),
        const .new(
          fotoKind: FotoIconKind.share,
          action: ShareAction(source: .timeline),
        ),
        const .new(
          fotoKind: FotoIconKind.link,
          action: ShareLinkAction(source: .timeline),
        ),

        if (ownsAlbum) ...const [
          .new(
            fotoKind: FotoIconKind.archive,
            action: ArchiveAction(source: .timeline),
          ),
          .new(
            fotoKind: FotoIconKind.favorite,
            action: FavoriteAction(source: .timeline),
          ),
        ],
        const .new(
          fotoKind: FotoIconKind.download,
          action: DownloadAction(source: .timeline),
        ),
        if (ownsAlbum) ...const [
          .new(action: EditDateTimeAction(source: .timeline)),
          .new(action: EditLocationAction(source: .timeline)),
          .new(
            fotoKind: FotoIconKind.lock,
            action: LockAction(source: .timeline),
          ),
          .new(
            fotoKind: FotoIconKind.stack,
            action: StackAction(source: .timeline),
          ),
          .new(
            fotoKind: FotoIconKind.stack,
            action: ManageStackAction(source: .timeline),
          ),
        ],
        if (ownsAlbum) ...[
          ActionColumnButton(
            fotoKind: FotoIconKind.removeAlbum,
            action: RemoveFromAlbumAction(source: .timeline, albumId: widget.album.id),
          ),
          ActionColumnButton(
            fotoKind: FotoIconKind.cover,
            action: SetAlbumCoverAction(source: .timeline, albumId: widget.album.id),
          ),
        ],
      ],
      // #965: the same picker the main timeline offers, so a space album is reachable from
      // inside an album too — not only from the timeline.
      // #965 follow-up: adding assets to a collection needs rights over the DESTINATION, never over
      // the source album -- the picker and the server both enforce that. Web gates this on view mode
      // only, with no ownership test. Every other ownsAlbum branch above is deliberately unchanged.
      slivers: [CollectionPicker(onKeyboardExpanded: onKeyboardExpand)],
    );
  }
}
