import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:immich_mobile/utils/deletion_message.dart';
import 'package:immich_mobile/utils/error_handler.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';

typedef _DeletionMessage = ({String message, bool complete});

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

      if (result.complete) {
        toastService.success(result.message, toast: undo);
        clearSelection();
      } else {
        // Keep failed device/server selections available for review and retry.
        toastService.error(result.message);
      }
    } catch (error, stack) {
      handleError(error, stack: stack, description: "Failed to delete assets");
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
      return (message: message, complete: true);
    }
    // Server acceptance precedes any device operation: an offline/uncertain
    // server request must not remove the phone's only available copy.
    final local = await _cleanupLocalAssetsDetailed(context, ref, localIds);
    if (!context.mounted) {
      return null;
    }
    return (message: '$message. ${_deviceResult(context, ref, local)}', complete: local.remainingIds.isEmpty);
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

    final results = await assetService.deleteWithResults(remoteIds);
    if (!context.mounted) {
      return null;
    }
    final completed = results.where((result) => result.complete).map((result) => result.id).toSet();
    final incomplete = results
        .where((result) => !result.complete)
        .map((result) => deletionMessage(context, result))
        .take(25)
        .join(', ');
    return (
      message: context.t.permanent_deletion_result(
        removed: completed.length,
        remaining: results.length - completed.length,
        reasons: incomplete,
      ),
      complete: completed.length == results.length,
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
    final assetIds = ref.read(_cleanupStateProvider(source));
    if (assetIds == null) {
      return;
    }

    final toastService = ref.read(toastServiceProvider);
    final clearSelection = ref.read(clearSelectionProvider(source));

    try {
      final result = await _cleanupLocalAssetsDetailed(context, ref, assetIds);
      if (!context.mounted) {
        return;
      }

      final selected = ref.read(assetsActionProvider(source));
      final names = result.remainingIds
          .map((id) => selected.where((asset) => asset.localId == id).firstOrNull?.name ?? id)
          .take(25)
          .join(', ');
      final message = context.t.device_deletion_result(
        removed: result.deletedIds.length,
        remaining: result.remainingIds.length,
        names: names,
      );
      if (result.remainingIds.isEmpty) {
        toastService.success(message);
        clearSelection();
      } else {
        toastService.error(message);
      }
    } catch (error, stack) {
      handleError(error, stack: stack, description: "Failed to remove the device copies");
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

  return cleanupService.deleteLocalAssetsDetailed(assetIds, trash: trash);
}
