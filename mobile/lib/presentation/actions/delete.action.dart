import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:immich_mobile/utils/deletion_message.dart';
import 'package:immich_mobile/utils/error_handler.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';

typedef _DeletionMessage = ({String message, bool success});

// Shared by the action's button/menu variants. Retained callbacks must not
// submit a second confirmation or request while the first snapshot is pending.
class _PermanentDeletionGuard {
  bool running = false;
}

final _permanentDeletionGuardProvider = Provider.family<_PermanentDeletionGuard, ActionSource>(
  (ref, source) => _PermanentDeletionGuard(),
  dependencies: [assetsActionProvider],
);

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
    if (!state.trash) {
      ref.watch(_permanentDeletionGuardProvider(source));
    }

    return .new(
      icon: Icons.delete_outline,
      label: !state.trash
          ? context.t.delete_permanently
          : removeLocalCopies
          ? context.t.delete_everywhere
          : "В корзину",
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
    final clearSelection = ref.read(clearSelectionProvider(source));
    final viewerState = source == .viewer ? ref.read(assetViewerProvider) : null;
    final deletedStackIndex = viewerState?.stackIndex ?? 0;
    final deletedStackAsset = viewerState?.currentAsset;
    final guard = trash ? null : ref.read(_permanentDeletionGuardProvider(source));
    if (guard?.running == true) {
      return;
    }
    if (guard != null) {
      guard.running = true;
    }

    try {
      var trashIds = remoteIds;
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
          trashIds = await assetService.resolveStackTrashIds(remoteIds, covers);
          if (!context.mounted) {
            return;
          }
          if (ref.read(authUserProvider).id != userId || store.tryGet(StoreKey.serverEndpoint) != endpoint) {
            throw StateError('Account or server changed while resolving selected stacks');
          }
        }
      }
      final _DeletionMessage? result;
      // Only trashing is reversible; a permanent delete and a device cleanup are not.
      ToastOption? undo;
      if (trash) {
        result = await _moveToTrash(context, ref, trashIds, removeLocalCopies ? localIds : const []);
        if (!removeLocalCopies) {
          undo = .new(onUndo: () => assetService.restoreTrash(trashIds));
        }
      } else {
        result = await _deletePermanently(context, ref, remoteIds);
      }

      if (result == null) {
        return;
      }

      if (result.success) {
        toastService.success(result.message, toast: undo);
        if (trash) {
          clearSelection();
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
      handleError(error, stack: stack, description: "Failed to delete assets");
    } finally {
      if (guard != null) {
        guard.running = false;
      }
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
  ) async {
    await ref.read(assetServiceProvider).trash(remoteIds);
    if (!context.mounted) {
      return null;
    }
    final message = context.t.trash_action_prompt(count: remoteIds.length);
    if (!removeLocalCopies) {
      return (message: message, success: true);
    }
    // Server acceptance precedes any device operation: an offline/uncertain
    // server request must not remove the phone's only available copy.
    final local = await _cleanupLocalAssetsDetailed(context, ref, localIds);
    if (!context.mounted) {
      return null;
    }
    return (message: '$message. ${_deviceResult(context, ref, local)}', success: local.remainingIds.isEmpty);
  }

  Future<_DeletionMessage?> _deletePermanently(BuildContext context, WidgetRef ref, List<String> remoteIds) async {
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

    final results = await assetService.acceptPermanentDeletion(remoteIds);
    if (!context.mounted) {
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

class _LocalCleanupGuard {
  bool running = false;
}

final _localCleanupGuardProvider = Provider.family<_LocalCleanupGuard, ActionSource>(
  (ref, source) => _LocalCleanupGuard(),
  dependencies: [assetsActionProvider],
);

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
    final guard = ref.read(_localCleanupGuardProvider(source));
    if (guard.running) {
      return;
    }
    final assetIds = ref.read(_cleanupStateProvider(source));
    if (assetIds == null) {
      return;
    }

    final userId = ref.read(currentUserProvider)?.id;
    final store = ref.read(storeServiceProvider);
    final endpoint = store.tryGet(StoreKey.serverEndpoint);
    bool isCurrent() =>
        context.mounted &&
        ref.read(currentUserProvider)?.id == userId &&
        store.tryGet(StoreKey.serverEndpoint) == endpoint;
    final toastService = ref.read(toastServiceProvider);

    guard.running = true;
    try {
      final result = await _cleanupLocalAssetsDetailed(context, ref, assetIds, canContinue: isCurrent);
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
      guard.running = false;
    }
  }
}

/// Explicit device-only cleanup. Album membership is a selection, not permission
/// to remove a server asset or delete the album's Drift definition.
class CleanupLocalAlbumAction extends ActionBuilder {
  const CleanupLocalAlbumAction({required this.albumId});

  final String albumId;

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
    final guard = ref.read(_localCleanupGuardProvider(.timeline));
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
      final snapshot = {for (final asset in await repository.getAssets(albumId)) asset.id: asset};
      if (!context.mounted || !isCurrent()) {
        return;
      }
      if (snapshot.isEmpty) {
        toastService.error(context.t.no_assets_to_show);
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => ConfirmDialog(
          title: context.t.delete_local_album_assets,
          content: context.t.delete_local_album_assets_confirmation(count: snapshot.length),
          ok: context.t.delete_from_device,
        ),
      );
      if (confirmed != true || !isCurrent()) {
        return;
      }

      // Do not add newly arrived items or remove a file that moved away/changed
      // while the user was reading the confirmation.
      final current = await repository.getAssets(albumId);
      if (!context.mounted || !isCurrent()) {
        return;
      }
      final eligible = <String>[
        for (final asset in current)
          if (snapshot[asset.id] case final LocalAsset previous
              when previous.type == asset.type &&
                  previous.name == asset.name &&
                  previous.checksum == asset.checksum &&
                  previous.createdAt.isAtSameMomentAs(asset.createdAt) &&
                  previous.updatedAt.isAtSameMomentAs(asset.updatedAt))
            asset.id,
      ];
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
      final removed = result.deletedIds.where(snapshot.containsKey).toSet();
      final remaining = snapshot.keys.where((id) => !removed.contains(id)).length;
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

/// Removes the device copies of [assetIds], returning how many were deleted.
///
/// iOS and Android without MANAGE_MEDIA prompt the user
/// with MANAGE_MEDIA, we do it ourselves unless [requestCustomPrompt] is false.
Future<LocalDeletionResult> _cleanupLocalAssetsDetailed(
  BuildContext context,
  WidgetRef ref,
  List<String> assetIds, {
  bool requestCustomPrompt = true,
  bool trash = true,
  bool Function()? canContinue,
}) async {
  if (assetIds.isEmpty) {
    return const LocalDeletionResult(deletedIds: [], remainingIds: []);
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
      return LocalDeletionResult(deletedIds: const [], remainingIds: assetIds);
    }
  }

  if (!context.mounted || canContinue?.call() == false) {
    return LocalDeletionResult(deletedIds: const [], remainingIds: assetIds);
  }
  return cleanupService.deleteLocalAssetsDetailed(assetIds, trash: trash);
}
