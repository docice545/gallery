import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:immich_mobile/utils/deletion_message.dart';
import 'package:immich_mobile/utils/error_handler.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';

typedef _State = ({List<String> localIds, List<String> localOnlyIds, List<String> remoteIds, bool trash});

final _stateProvider = Provider.family.autoDispose<_State?, ActionSource>((ref, source) {
  final assets = ref.watch(assetsActionProvider(source));
  final authUserId = ref.watch(authUserProvider).id;

  final localIds = <String>[];
  final localOnlyIds = <String>[];
  final ownedRemote = <RemoteAsset>[];
  for (final asset in assets) {
    if ((asset.isLocalOnly || asset is RemoteAsset && asset.ownerId == authUserId) && asset.localId != null) {
      final localId = asset.localId!;
      localIds.add(localId);
      if (asset.isLocalOnly) {
        localOnlyIds.add(localId);
      }
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
  final trash = ownedRemote.isEmpty || !ownedRemote.every((asset) => asset.isTrashed);

  return (
    localIds: localIds,
    localOnlyIds: localOnlyIds,
    remoteIds: ownedRemote.map((asset) => asset.id).toList(growable: false),
    trash: trash,
  );
}, dependencies: [assetsActionProvider]);

class DeleteAction extends AssetActionBuilder {
  const DeleteAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final trash = ref.watch(_stateProvider(source).select((state) => state?.trash));
    if (trash == null) {
      return null;
    }

    return .new(
      icon: Icons.delete_outline,
      label: trash ? context.t.trash : context.t.delete,
      onAction: () => _delete(context, ref),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final state = ref.read(_stateProvider(source));
    if (state == null) {
      return;
    }

    final (:localIds, localOnlyIds: _, :remoteIds, :trash) = state;
    final assetService = ref.read(assetServiceProvider);
    final toastService = ref.read(toastServiceProvider);
    final clearSelection = ref.read(clearSelectionProvider(source));

    try {
      final String? message;
      // Only trashing is reversible; a permanent delete and a device cleanup are not.
      ToastOption? undo;
      if (remoteIds.isEmpty) {
        message = await _removeLocalAssets(context, ref, localIds);
      } else if (trash) {
        message = await _moveToTrash(context, ref, remoteIds, localIds);
        undo = .new(onUndo: () => assetService.restoreTrash(remoteIds));
      } else {
        message = await _deletePermanently(context, ref, remoteIds, localIds);
      }

      if (message == null) {
        return;
      }

      toastService.success(message, toast: undo);
      clearSelection();
    } catch (error, stack) {
      handleError(error, stack: stack, description: "Failed to delete assets");
    }
  }

  Future<String?> _removeLocalAssets(BuildContext context, WidgetRef ref, List<String> localIds) async {
    final result = await _cleanupLocalAssetsDetailed(context, ref, localIds);
    if (!context.mounted) {
      return null;
    }
    return _deviceResult(context, ref, result);
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

  Future<String?> _moveToTrash(
    BuildContext context,
    WidgetRef ref,
    List<String> remoteIds,
    List<String> localIds,
  ) async {
    await ref.read(assetServiceProvider).trash(remoteIds);
    if (!context.mounted) {
      return null;
    }
    final result = await _cleanupLocalAssetsDetailed(context, ref, localIds);
    if (!context.mounted) {
      return null;
    }
    return '${context.t.trash_action_prompt(count: remoteIds.length)}. ${_deviceResult(context, ref, result)}';
  }

  Future<String?> _deletePermanently(
    BuildContext context,
    WidgetRef ref,
    List<String> remoteIds,
    List<String> localIds,
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

    final results = await assetService.deleteWithResults(remoteIds);
    if (!context.mounted) {
      return null;
    }
    final completed = results.where((result) => result.complete).map((result) => result.id).toSet();
    final assets = ref.read(assetsActionProvider(source));
    final permittedLocalIds = assets
        .where((asset) => completed.contains(asset.remoteId))
        .map((asset) => asset.localId)
        .nonNulls
        .toList();
    final retainedLocalIds = await assetService.getDeletionLocalIds(completed.toList());
    if (!context.mounted) {
      return null;
    }
    final local = await _cleanupLocalAssetsDetailed(
      context,
      ref,
      {...permittedLocalIds, ...retainedLocalIds}.toList(),
      requestCustomPrompt: false,
      trash: false,
    );
    if (!context.mounted) {
      return null;
    }
    final incomplete = results
        .where((result) => !result.complete)
        .map((result) => deletionMessage(context, result))
        .take(25)
        .join(', ');
    return '${context.t.permanent_deletion_result(removed: completed.length, remaining: results.length - completed.length, reasons: incomplete)}. ${_deviceResult(context, ref, local)}';
  }
}

final _cleanupStateProvider = Provider.family.autoDispose<List<String>?, ActionSource>((ref, source) {
  final assets = ref.watch(assetsActionProvider(source));
  final assetIds = assets.backedUp().map((asset) => asset.localId).nonNulls.toList(growable: false);
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
      label: context.t.control_bottom_app_bar_delete_from_local,
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
      final count = await _cleanupLocalAssets(context, ref, assetIds);
      if (count <= 0 || !context.mounted) {
        return;
      }

      toastService.success(context.t.cleanup_deleted_assets(count: count));
      clearSelection();
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

Future<int> _cleanupLocalAssets(BuildContext context, WidgetRef ref, List<String> ids) async =>
    (await _cleanupLocalAssetsDetailed(context, ref, ids)).deletedIds.length;
