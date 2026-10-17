import 'dart:async';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/repositories/album_api_repository.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/repositories/shared_space_api.repository.dart';

final actionServiceProvider = Provider<ActionService>(
  (ref) => ActionService(
    ref.watch(assetApiRepositoryProvider),
    ref.watch(driftProvider).remoteAssetRepository,
    ref.watch(sharedSpaceApiRepositoryProvider),
    ref.watch(albumApiRepositoryProvider),
    ref.watch(driftProvider).remoteAlbumRepository,
  ),
);

class ActionService {
  final AssetApiRepository _assetApiRepository;
  final RemoteAssetRepository _remoteAssetRepository;
  final SharedSpaceApiRepository _sharedSpaceApiRepository;
  final AlbumApiRepository _albumApiRepository;
  final RemoteAlbumRepository _remoteAlbumRepository;

  const ActionService(
    this._assetApiRepository,
    this._remoteAssetRepository,
    this._sharedSpaceApiRepository,
    this._albumApiRepository,
    this._remoteAlbumRepository,
  );

  /// Fork-only: removing an asset from a Space is NOT owner-scoped — an editor
  /// may remove another member's photo. Callers must resolve ids via
  /// `_getRemoteIdsForSource`, never `_getOwnedRemoteIdsForSource`.
  Future<int> removeFromSpace(List<String> remoteIds, String spaceId) async {
    await _sharedSpaceApiRepository.removeAssets(spaceId, remoteIds);
    return remoteIds.length;
  }

  /// Retained after upstream migrated remove-from-album into
  /// `remove_from_album.action.dart`: the fork's `ActionNotifier.removeFromAlbum`
  /// additionally fires `_nudgeSpaceSyncIfLinked`, which upstream's action has no
  /// hook for, and fork-only `SpaceAlbumBottomSheet` depends on that path.
  Future<int> removeFromAlbum(List<String> remoteIds, String albumId) async {
    final result = await _albumApiRepository.removeAssets(albumId, remoteIds);
    if (result.removed.isNotEmpty) {
      await _remoteAlbumRepository.removeAssets(albumId, result.removed);
    }
    return result.removed.length;
  }

  Future<({int completed, int remaining})> emptyTrash(String userId) async {
    // Empty Trash must use the same owner-scoped, per-item reconciliation as
    // the Trash page. The count-only endpoint cannot tell us which rows were
    // physically deleted when a batch is partial or races retention.
    final ids = await _remoteAssetRepository.getTrashIds(userId);
    if (ids.isEmpty) {
      return (completed: 0, remaining: 0);
    }

    final snapshots = await _remoteAssetRepository.beginPermanentDeletion(ids);
    List<PermanentDeletionResult> results;
    try {
      results = await _assetApiRepository.permanentlyDelete(ids);
    } catch (error, stack) {
      await _remoteAssetRepository.completeTrashOperation(snapshots, success: false);
      Error.throwWithStackTrace(error, stack);
    }

    // Resolve each receipt independently. Failed/blocked items remain in
    // Trash and can be retried; completed items are removed from the cache.
    for (final result in results) {
      final checked = snapshots.where((snapshot) => snapshot.id == result.id).toList();
      if (result.state == 'uncertain') {
        await _remoteAssetRepository.completeTrashOperation(checked, success: false);
      } else {
        await _remoteAssetRepository.completePermanentDeletion(
          checked,
          result.state == 'blocked' ? const [] : [result.id],
          result.complete ? [result.id] : const [],
        );
      }
    }
    final completed = results.where((result) => result.complete).length;
    return (completed: completed, remaining: results.length - completed);
  }

  Future<int> restoreAllTrash(String userId) async {
    final snapshots = await _remoteAssetRepository.beginRestoreAllTrash(userId);
    try {
      final count = await _assetApiRepository.restoreAllTrash();
      // A count cannot identify which of the captured rows was restored when
      // retention/permanent deletion ran concurrently. Preserve revision-guarded
      // pending state until ordinary sync verifies each captured asset.
      await _remoteAssetRepository.completeTrashOperation(snapshots, success: false);
      return count;
    } catch (error, stack) {
      try {
        await _remoteAssetRepository.completeTrashOperation(
          snapshots,
          success: false,
          definiteFailure: AssetApiRepository.isDefiniteTrashRejection(error),
        );
      } finally {
        Error.throwWithStackTrace(error, stack);
      }
    }
  }

  Future<bool> updateDescription(String assetId, String description) async {
    // update remote first, then local to ensure consistency
    await _assetApiRepository.updateDescription(assetId, description);
    await _remoteAssetRepository.updateDescription(assetId, description);

    return true;
  }

  Future<bool> updateRating(String assetId, int? rating) async {
    // update remote first, then local to ensure consistency
    await _assetApiRepository.updateRating(assetId, rating);
    await _remoteAssetRepository.updateRating(assetId, rating);

    return true;
  }
}
