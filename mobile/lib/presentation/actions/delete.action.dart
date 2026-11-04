import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/album/album_trash_snapshot.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/deletion_snapshot.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/repositories/album_api_repository.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:immich_mobile/utils/deletion_message.dart';
import 'package:immich_mobile/utils/error_handler.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';

typedef _DeletionMessage = ({String message, bool success});

// Shared by the action's button/menu variants. Retained callbacks must not
// submit a second confirmation or request while the first snapshot is pending.
class _DeletionGuard {
  bool running = false;
}

final _deletionGuardProvider = Provider.family<_DeletionGuard, ActionSource>(
  (ref, source) => _DeletionGuard(),
  dependencies: [assetsActionProvider],
);

/// Consent expires when selection, route, account, server or underlying rows
/// change. A 1→many→1 sequence also expires it, even when IDs happen to match.
class _SelectionDeletionLease {
  final BuildContext context;
  final WidgetRef ref;
  final ActionSource source;
  final DeletionSnapshot snapshot;
  final String? userId;
  final String? endpoint;
  final int? revision;
  final MultiSelectNotifier? selection;
  late final StreamSubscription<TimelineReloadEvent> _reload;
  bool _invalid = false;

  _SelectionDeletionLease(this.context, this.ref, this.source)
    : snapshot = DeletionSnapshot(ref.read(assetsActionProvider(source))),
      userId = ref.read(currentUserProvider)?.id,
      endpoint = ref.read(storeServiceProvider).tryGet(StoreKey.serverEndpoint),
      revision = source == .timeline ? ref.read(multiSelectProvider).revision : null,
      selection = source == .timeline ? ref.read(multiSelectProvider.notifier) : null {
    _reload = EventStream.shared.listen<TimelineReloadEvent>((_) => _invalid = true);
  }

  bool isSessionCurrent() =>
      context.mounted &&
      ref.read(currentUserProvider)?.id == userId &&
      ref.read(storeServiceProvider).tryGet(StoreKey.serverEndpoint) == endpoint;

  bool isSelectionCurrent() =>
      isSessionCurrent() &&
      (source != .timeline ||
          (ref.read(multiSelectProvider).revision == revision &&
              identical(ref.read(multiSelectProvider.notifier), selection))) &&
      snapshot.matches(ref.read(assetsActionProvider(source)));

  bool isCurrent() => !_invalid && isSelectionCurrent();

  Future<bool> validate() async {
    if (!isCurrent()) {
      return false;
    }
    final matches = await snapshot.matchesStored(ref.read(assetServiceProvider).getAsset);
    return matches && isCurrent();
  }

  void dispose() {
    _invalid = true;
    unawaited(_reload.cancel());
  }
}

Future<GhostFlight?> _prepareDeletionVisual(
  BuildContext context,
  WidgetRef ref,
  ActionSource source,
  GhostTrashKind kind,
) async {
  final keys = ref
      .read(assetsActionProvider(source))
      .where((asset) => asset.isImage)
      .map((asset) => asset.heroTag)
      .toList();
  if (source == ActionSource.viewer && ref.read(isPlayingMotionVideoProvider)) {
    ref.read(isPlayingMotionVideoProvider.notifier).playing = false;
    await WidgetsBinding.instance.endOfFrame;
  }
  if (!context.mounted) {
    return null;
  }
  return ref.read(ghostTrapProvider).prepare(context, keys, kind);
}

typedef _State = ({List<String> localIds, List<String> remoteIds, bool trash});

final _stateProvider = Provider.family.autoDispose<_State?, ActionSource>((ref, source) {
  final assets = ref.watch(assetsActionProvider(source));
  final authUserId = ref.watch(authUserProvider).id;

  final localIds = <String>[];
  final ownedRemote = <RemoteAsset>[];
  final linkedLocalRemoteIds = <String>{};
  for (final asset in assets) {
    if ((asset is LocalAsset || asset is RemoteAsset && asset.ownerId == authUserId) && asset.localId != null) {
      final localId = asset.localId!;
      localIds.add(localId);
    }
    // LocalAsset.remoteId comes from LocalAssetRepository/TimelineRepository's
    // checksum join restricted to the current auth user's remote rows. Local
    // album/viewer representations must retain the same cloud actions. The API
    // still checks ownership before accepting any mutation.
    if (asset is LocalAsset && asset.remoteId != null) {
      linkedLocalRemoteIds.add(asset.remoteId!);
    }
    if (asset case final RemoteAsset remote when remote.ownerId == authUserId) {
      ownedRemote.add(remote);
    }
  }

  if (localIds.isEmpty && ownedRemote.isEmpty) {
    return null;
  }

  // Timeline deletion always means recoverable server Trash, including Locked assets.
  // Permanent deletion is available only for assets already in Trash and requires confirmation.
  final trash =
      linkedLocalRemoteIds.isNotEmpty || ownedRemote.isEmpty || !ownedRemote.every((asset) => asset.isTrashed);

  return (
    localIds: localIds.toSet().toList(growable: false),
    remoteIds: {...ownedRemote.map((asset) => asset.id), ...linkedLocalRemoteIds}.toList(growable: false),
    trash: trash,
  );
}, dependencies: [assetsActionProvider]);

class DeleteAction extends AssetActionBuilder {
  const DeleteAction({required super.source, this.removeLocalCopies = false});

  final bool removeLocalCopies;

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final state = ref.watch(_stateProvider(source));
    if (state == null || state.remoteIds.isEmpty || (removeLocalCopies && (!state.trash || state.localIds.isEmpty))) {
      return null;
    }
    ref.watch(_deletionGuardProvider(source));

    return .new(
      icon: Icons.delete_outline,
      label: !state.trash
          ? context.t.delete_permanently
          : removeLocalCopies
          ? context.t.delete_everywhere
          : context.t.move_to_server_trash,
      onAction: () => _delete(context, ref),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final state = ref.read(_stateProvider(source));
    if (state == null) {
      return;
    }

    final (:localIds, :remoteIds, :trash) = state;
    final assetService = ref.read(assetServiceProvider);
    final toastService = ref.read(toastServiceProvider);
    final viewerState = source == .viewer ? ref.read(assetViewerProvider) : null;
    final deletedStackIndex = viewerState?.stackIndex ?? 0;
    final deletedStackAsset = viewerState?.currentAsset;
    final guard = ref.read(_deletionGuardProvider(source));
    if (guard.running) {
      return;
    }
    guard.running = true;
    final lease = _SelectionDeletionLease(context, ref, source);
    GhostFlight? visual;

    try {
      var trashIds = remoteIds;
      var expandedCovers = <RemoteAsset>[];
      if (trash && source == .timeline) {
        final covers = ref
            .read(ownedAssetsActionProvider(source))
            .where((asset) => asset.stackId != null)
            .toList(growable: false);
        // Main Photos collapses stacks in its query. Viewer (even its primary),
        // flat album/search/map and Trash selections still denote single frames.
        if (covers.isNotEmpty && ref.read(timelineServiceProvider).origin == TimelineOrigin.main) {
          final userId = ref.read(authUserProvider).id;
          final store = ref.read(storeServiceProvider);
          final endpoint = store.tryGet(StoreKey.serverEndpoint);
          expandedCovers = covers;
          trashIds = await assetService.resolveStackTrashIds(remoteIds, covers);
          if (!context.mounted) {
            return;
          }
          if (ref.read(authUserProvider).id != userId || store.tryGet(StoreKey.serverEndpoint) != endpoint) {
            throw StateError('Account or server changed while resolving selected stacks');
          }
        }
      }
      if (!await lease.validate()) {
        if (context.mounted) {
          toastService.error(context.t.deletion_selection_changed);
        }
        return;
      }
      if (!context.mounted) {
        return;
      }
      final _DeletionMessage? result;
      // Only trashing is reversible; a permanent delete and a device cleanup are not.
      ToastOption? undo;
      if (trash) {
        visual = await _prepareDeletionVisual(context, ref, source, GhostTrashKind.server);
        if (expandedCovers.isNotEmpty) {
          final refreshed = await assetService.resolveStackTrashIds(remoteIds, expandedCovers);
          if (refreshed.length != trashIds.length || !refreshed.toSet().containsAll(trashIds)) {
            if (context.mounted) {
              toastService.error(context.t.deletion_selection_changed);
            }
            return;
          }
        }
        if (!await lease.validate()) {
          if (context.mounted) {
            toastService.error(context.t.deletion_selection_changed);
          }
          return;
        }
        if (!context.mounted || !lease.isSessionCurrent()) {
          return;
        }
        result = await _moveToTrash(context, ref, trashIds, removeLocalCopies ? localIds : const [], lease, visual);
        if (!removeLocalCopies) {
          // A snackbar can outlive the selection sheet. Capture services and
          // identity, not a disposed WidgetRef; never restore into a new account/server.
          final users = ref.read(userServiceProvider);
          final store = ref.read(storeServiceProvider);
          final acceptedIds = List<String>.unmodifiable(trashIds);
          undo = .new(
            onUndo: () async {
              if (users.tryGetMyUser()?.id != lease.userId || store.tryGet(StoreKey.serverEndpoint) != lease.endpoint) {
                return;
              }
              await assetService.restoreTrash(acceptedIds);
            },
          );
        }
      } else {
        result = await _deletePermanently(context, ref, remoteIds, lease);
      }

      if (result == null || !lease.isSessionCurrent()) {
        return;
      }
      if (result.success) {
        toastService.success(result.message, toast: undo);
        if (trash) {
          // A response owns only the captured IDs. New selections and local-only
          // photos must not disappear with an older server request.
          if (source == .timeline) {
            final accepted = remoteIds.toSet();
            final removedLocal = removeLocalCopies ? localIds.toSet() : const <String>{};
            final selection = ref.read(multiSelectProvider.notifier);
            for (final asset in ref.read(assetsActionProvider(source)).toList()) {
              if (accepted.contains(asset.remoteId) || removedLocal.contains(asset.localId)) {
                selection.deselectAsset(asset);
              }
            }
          }
          if (source == .viewer &&
              remoteIds.length == 1 &&
              deletedStackAsset is RemoteAsset &&
              deletedStackAsset.stackId != null &&
              deletedStackAsset.id == remoteIds.single) {
            EventStream.shared.emit(
              ViewerStackAssetDeletedEvent(
                stackIndex: deletedStackIndex,
                assetId: deletedStackAsset.id,
                stackId: deletedStackAsset.stackId!,
              ),
            );
          }
        }
      } else {
        // Keep failed device/server selections available for review and retry.
        toastService.error(result.message);
      }
    } catch (error, stack) {
      if (lease.isSessionCurrent()) {
        handleError(error, stack: stack, description: "Failed to delete assets");
      }
    } finally {
      visual?.cancel();
      lease.dispose();
      guard.running = false;
    }
  }

  String _deviceResult(BuildContext context, WidgetRef ref, LocalDeletionResult result) {
    final assets = ref.read(assetsActionProvider(source));
    final names = result.remainingIds
        .map((id) => assets.where((asset) => asset.localId == id).firstOrNull?.name ?? id)
        .take(25)
        .join(', ');
    return context.t.device_deletion_result(
      removed: result.deletedIds.length,
      remaining: result.remainingIds.length,
      names: names,
    );
  }

  Future<_DeletionMessage?> _moveToTrash(
    BuildContext context,
    WidgetRef ref,
    List<String> remoteIds,
    List<String> localIds,
    _SelectionDeletionLease lease,
    GhostFlight? visual,
  ) async {
    await ref.read(assetServiceProvider).trash(remoteIds);
    if (lease.isSessionCurrent()) {
      await visual?.confirmed();
    }
    if (!context.mounted || !lease.isSessionCurrent()) {
      return null;
    }
    final message = context.t.trash_action_prompt(count: remoteIds.length);
    if (!removeLocalCopies) {
      return (message: message, success: true);
    }
    // Server acceptance precedes any device operation: an offline/uncertain
    // server request must not remove the phone's only available copy.
    final local = await _cleanupLocalAssetsDetailed(context, ref, localIds, canContinue: lease.isSelectionCurrent);
    if (!context.mounted) {
      return null;
    }
    if (local == null) {
      return (
        message: '$message. ${context.t.device_deletion_summary(removed: 0, remaining: localIds.length)}',
        success: false,
      );
    }
    return (message: '$message. ${_deviceResult(context, ref, local)}', success: local.remainingIds.isEmpty);
  }

  Future<_DeletionMessage?> _deletePermanently(
    BuildContext context,
    WidgetRef ref,
    List<String> remoteIds,
    _SelectionDeletionLease lease,
  ) async {
    final assetService = ref.read(assetServiceProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: context.t.delete_dialog_title,
        content: context.t.delete_dialog_alert,
        ok: context.t.delete_permanently,
      ),
    );
    if (confirmed != true || !context.mounted) {
      return null;
    }

    if (!await lease.validate()) {
      if (context.mounted) {
        ref.read(toastServiceProvider).error(context.t.deletion_selection_changed);
      }
      return null;
    }
    final results = await assetService.acceptPermanentDeletion(remoteIds);
    if (!context.mounted || !lease.isSessionCurrent()) {
      return null;
    }
    final requested = remoteIds.toSet();
    final accepted = results
        .where((result) => result.accepted && requested.contains(result.id))
        .map((result) => result.id)
        .toSet();
    if (source == ActionSource.timeline) {
      // The service already retired only server-acknowledged Drift rows. Remove
      // those exact IDs from selection too; rejected/new selections stay usable.
      final selection = ref.read(multiSelectProvider.notifier);
      final acceptedAssets = ref
          .read(assetsActionProvider(source))
          .where((asset) => asset is RemoteAsset && accepted.contains(asset.id))
          .toList(growable: false);
      for (final asset in acceptedAssets) {
        selection.deselectAsset(asset);
      }
    }
    if (accepted.length == requested.length) {
      return (message: context.t.permanent_deletion_accepted(count: accepted.length), success: true);
    }
    final reasons = results
        .where((result) => !result.accepted)
        .map((result) => deletionMessage(context, result))
        .toSet()
        .join(', ');
    return (
      message: context.t.trash_cleanup_partial(
        count: accepted.length,
        remaining: requested.length - accepted.length,
        reasons: reasons,
      ),
      success: false,
    );
  }
}

/// Moves owned server assets to Trash and then requests OS-authorized device cleanup.
/// Unlike Gallery-only Trash, undo cannot recreate intentionally removed device files.
class DeleteEverywhereAction extends DeleteAction {
  const DeleteEverywhereAction({required super.source}) : super(removeLocalCopies: true);
}

final _cleanupStateProvider = Provider.family.autoDispose<List<String>?, ActionSource>((ref, source) {
  final assets = ref.watch(assetsActionProvider(source));
  final userId = ref.watch(authUserProvider).id;
  final assetIds = assets
      .where((asset) => asset is LocalAsset || asset is RemoteAsset && asset.ownerId == userId)
      .map((asset) => asset.localId)
      .nonNulls
      .toSet()
      .toList(growable: false);
  return assetIds.isEmpty ? null : assetIds;
}, dependencies: [assetsActionProvider]);

class CleanupLocalAction extends AssetActionBuilder {
  const CleanupLocalAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final isVisible = ref.watch(_cleanupStateProvider(source).select((state) => state != null));
    if (!isVisible) {
      return null;
    }

    return .new(
      icon: Icons.no_cell_outlined,
      label: context.t.delete_from_device,
      onAction: () => _cleanup(context, ref),
    );
  }

  Future<void> _cleanup(BuildContext context, WidgetRef ref) async {
    if (!context.mounted) {
      return;
    }
    final guard = ref.read(_deletionGuardProvider(source));
    if (guard.running) {
      return;
    }
    final assetIds = ref.read(_cleanupStateProvider(source));
    if (assetIds == null) {
      return;
    }

    final lease = _SelectionDeletionLease(context, ref, source);
    bool isCurrent() => lease.isSessionCurrent();
    final toastService = ref.read(toastServiceProvider);

    GhostFlight? visual;
    guard.running = true;
    try {
      final result = await _cleanupLocalAssetsDetailed(
        context,
        ref,
        assetIds,
        canContinue: isCurrent,
        preflight: lease.validate,
        beforeOperation: () async {
          visual = await _prepareDeletionVisual(context, ref, source, GhostTrashKind.device);
          return visual == null || await lease.validate();
        },
      );
      if (result == null) {
        return;
      }
      if (!context.mounted || !isCurrent()) {
        return;
      }

      final representative = ref
          .read(assetsActionProvider(source))
          .where((asset) => asset.heroTag == visual?.assetKey)
          .firstOrNull;
      if (representative != null && result.deletedIds.contains(representative.localId)) {
        await visual?.confirmed();
      } else {
        visual?.cancel();
      }
      if (!context.mounted || !isCurrent()) {
        return;
      }
      if (source == .timeline && result.deletedIds.isNotEmpty) {
        final removed = result.deletedIds.toSet();
        final selected = ref.read(multiSelectProvider).selectedAssets.toList();
        final notifier = ref.read(multiSelectProvider.notifier);
        for (final asset in selected) {
          if (removed.contains(asset.localId)) {
            notifier.deselectAsset(asset);
          }
        }
      }
      final message = context.t.device_deletion_summary(
        removed: result.deletedIds.length,
        remaining: result.remainingIds.length,
      );
      if (result.remainingIds.isEmpty) {
        toastService.success(message);
      } else {
        toastService.error(message);
      }
    } catch (error, stack) {
      if (isCurrent()) {
        handleError(error, stack: stack, description: "Failed to remove the device copies");
      }
    } finally {
      visual?.cancel();
      lease.dispose();
      guard.running = false;
    }
  }
}

/// Explicit device-only cleanup. Album membership is a selection, not permission
/// to remove a server asset or delete the album's Drift definition.
class CleanupLocalAlbumAction extends ActionBuilder {
  const CleanupLocalAlbumAction({required this.albumId, required this.albumName, this.isShared = false});

  final String albumId;
  final String albumName;
  final bool isShared;

  @override
  ActionItem create(BuildContext context, WidgetRef ref) => .new(
    icon: Icons.delete_outline,
    label: context.t.delete_local_album_assets,
    onAction: () => _cleanupAlbum(context, ref),
  );

  Future<void> _cleanupAlbum(BuildContext context, WidgetRef ref) async {
    if (!context.mounted) {
      return;
    }
    if (isShared) {
      ref.read(toastServiceProvider).error(context.t.album_trash_scope_unsupported);
      return;
    }
    final guard = ref.read(_deletionGuardProvider(.timeline));
    if (guard.running) {
      return;
    }
    final userId = ref.read(currentUserProvider)?.id;
    final store = ref.read(storeServiceProvider);
    final endpoint = store.tryGet(StoreKey.serverEndpoint);
    bool isCurrent() =>
        context.mounted &&
        ref.read(currentUserProvider)?.id == userId &&
        store.tryGet(StoreKey.serverEndpoint) == endpoint;
    final repository = ref.read(driftProvider).localAlbumRepository;
    final toastService = ref.read(toastServiceProvider);

    guard.running = true;
    try {
      // getAssets joins live local rows. Raw album-link IDs can include stale
      // links and must never be interpreted as a MediaStore selection.
      final snapshotAssets = await repository.getAssets(albumId);
      final snapshot = DeletionSnapshot(snapshotAssets);
      if (!context.mounted || !isCurrent()) {
        return;
      }
      if (snapshot.assets.isEmpty) {
        toastService.error(context.t.no_assets_to_show);
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => ConfirmDialog(
          title: context.t.delete_album,
          content: context.t.album_delete_confirmation(album: albumName),
          ok: context.t.delete,
        ),
      );
      if (confirmed != true || !isCurrent()) {
        return;
      }

      final current = await repository.getAssets(albumId);
      if (!context.mounted || !isCurrent()) {
        return;
      }
      if (!snapshot.matches(current)) {
        toastService.error(context.t.deletion_selection_changed);
        return;
      }
      final eligible = snapshot.assets.map((asset) => asset.id).toList(growable: false);
      final result = await _cleanupLocalAssetsDetailed(
        context,
        ref,
        eligible,
        requestCustomPrompt: false,
        canContinue: isCurrent,
      );
      if (!context.mounted || !isCurrent()) {
        return;
      }
      if (result == null) {
        return;
      }
      final requested = eligible.toSet();
      final removed = result.deletedIds.where(requested.contains).toSet();
      final remaining = requested.difference(removed).length;
      if (removed.isNotEmpty) {
        final selected = ref.read(multiSelectProvider).selectedAssets.toList();
        final notifier = ref.read(multiSelectProvider.notifier);
        for (final asset in selected) {
          if (removed.contains(asset.localId)) {
            notifier.deselectAsset(asset);
          }
        }
      }
      final message = context.t.device_deletion_summary(removed: removed.length, remaining: remaining);
      if (remaining == 0) {
        toastService.success(message);
      } else {
        toastService.error(message);
      }
    } catch (error, stack) {
      if (isCurrent()) {
        handleError(error, stack: stack, description: "Failed to remove the album's device copies");
      }
    } finally {
      guard.running = false;
    }
  }
}

/// Private server albums: complete live membership -> consent -> revalidation
/// -> recoverable asset Trash -> remove the now-empty album definition.
class TrashRemoteAlbumAction extends ActionBuilder {
  const TrashRemoteAlbumAction({required this.albumId});
  final String albumId;

  @override
  ActionItem create(BuildContext context, WidgetRef ref) =>
      ActionItem(icon: Icons.delete_outline, label: context.t.delete_album, onAction: () => _trash(context, ref));

  Future<void> _trash(BuildContext context, WidgetRef ref) async {
    final guard = ref.read(_deletionGuardProvider(.timeline));
    if (guard.running || !context.mounted) {
      return;
    }
    final userId = ref.read(currentUserProvider)?.id;
    if (userId == null) {
      return;
    }
    final store = ref.read(storeServiceProvider);
    final endpoint = store.tryGet(StoreKey.serverEndpoint);
    bool current() =>
        context.mounted &&
        ref.read(currentUserProvider)?.id == userId &&
        store.tryGet(StoreKey.serverEndpoint) == endpoint;
    final repository = ref.read(albumApiRepositoryProvider);
    final toast = ref.read(toastServiceProvider);
    var photosTrashed = false;
    guard.running = true;
    try {
      final snapshot = await repository.getTrashSnapshot(albumId, userId);
      if (!context.mounted || !current()) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => ConfirmDialog(
          title: context.t.delete_album,
          content: context.t.album_delete_confirmation(album: snapshot.name),
          ok: context.t.delete,
        ),
      );
      if (confirmed != true || !current()) {
        return;
      }
      final latest = await repository.getTrashSnapshot(albumId, userId);
      if (!context.mounted || !current()) {
        return;
      }
      if (!snapshot.matches(latest)) {
        toast.error(context.t.deletion_selection_changed);
        return;
      }
      if (snapshot.assets.isNotEmpty) {
        await ref.read(assetServiceProvider).trash(snapshot.assetIds);
        photosTrashed = true;
      }
      if (!context.mounted || !current()) {
        return;
      }
      // New arrivals/shared access must not be silently removed with metadata.
      final empty = await repository.getTrashSnapshot(albumId, userId);
      if (!context.mounted || !current()) {
        return;
      }
      if (empty.assets.isNotEmpty) {
        toast.error(photosTrashed ? context.t.album_trash_incomplete : context.t.deletion_selection_changed);
        return;
      }
      await ref.read(remoteAlbumProvider.notifier).deleteAlbum(albumId);
      if (context.mounted && current()) {
        toast.success(context.t.album_deleted);
      }
    } on AlbumTrashScopeException {
      if (context.mounted && current()) {
        toast.error(photosTrashed ? context.t.album_trash_incomplete : context.t.album_trash_scope_unsupported);
      }
    } catch (error, stack) {
      if (context.mounted && current()) {
        if (photosTrashed) {
          toast.error(context.t.album_trash_incomplete);
        } else {
          handleError(error, stack: stack, description: 'Failed to trash album');
        }
      }
    } finally {
      guard.running = false;
    }
  }
}

/// Removes the device copies of [assetIds], returning how many were deleted.
///
/// iOS and Android without MANAGE_MEDIA prompt the user
/// with MANAGE_MEDIA, we do it ourselves unless [requestCustomPrompt] is false.
Future<LocalDeletionResult?> _cleanupLocalAssetsDetailed(
  BuildContext context,
  WidgetRef ref,
  List<String> assetIds, {
  bool requestCustomPrompt = true,
  bool trash = true,
  bool Function()? canContinue,
  Future<bool> Function()? preflight,
  Future<bool> Function()? beforeOperation,
}) async {
  if (assetIds.isEmpty) {
    return null;
  }

  final cleanupService = ref.read(cleanupServiceProvider);
  final requiresPrompt =
      requestCustomPrompt &&
      CurrentPlatform.isAndroid &&
      ref.read(storeServiceProvider).get(.manageLocalMediaAndroid, false);

  if (requiresPrompt) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: context.t.move_to_device_trash,
        content: context.t.free_up_space_description,
        ok: context.t.ok,
      ),
    );
    if (confirmed != true) {
      return null;
    }
  }

  if (!context.mounted || canContinue?.call() == false) {
    return null;
  }
  if (preflight != null && !await preflight()) {
    if (context.mounted) {
      ref.read(toastServiceProvider).error(context.t.deletion_selection_changed);
    }
    return null;
  }
  if (!context.mounted || canContinue?.call() == false) {
    return null;
  }
  if (beforeOperation != null && !await beforeOperation()) {
    if (context.mounted) {
      ref.read(toastServiceProvider).error(context.t.deletion_selection_changed);
    }
    return null;
  }
  if (!context.mounted || canContinue?.call() == false) {
    return null;
  }
  return cleanupService.deleteLocalAssetsDetailed(assetIds, trash: trash);
}
