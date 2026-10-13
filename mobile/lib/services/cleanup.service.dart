import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';

final cleanupServiceProvider = Provider<CleanupService>((ref) {
  final db = ref.watch(driftProvider);
  return CleanupService(
    db.localAssetRepository,
    ref.watch(assetMediaRepositoryProvider),
    trashedLocalRepository: db.trashedLocalAssetRepository,
  );
});

class CleanupService {
  static final int _deleteBatchSize = CurrentPlatform.isAndroid ? 2000 : 10000;

  final LocalAssetRepository _localAssetRepository;
  final AssetMediaRepository _assetMediaRepository;
  final TrashedLocalAssetRepository? _trashedLocalRepository;

  const CleanupService(
    this._localAssetRepository,
    this._assetMediaRepository, {
    TrashedLocalAssetRepository? trashedLocalRepository,
  }) : _trashedLocalRepository = trashedLocalRepository;

  Future<RemovalCandidatesResult> getRemovalCandidates(
    String userId,
    DateTime cutoffDate, {
    AssetKeepType keepMediaType = AssetKeepType.none,
    bool keepFavorites = true,
    Set<String> keepAlbumIds = const {},
  }) {
    return _localAssetRepository.getRemovalCandidates(
      userId,
      cutoffDate,
      keepMediaType: keepMediaType,
      keepFavorites: keepFavorites,
      keepAlbumIds: keepAlbumIds,
    );
  }

  Future<int> deleteLocalAssets(List<String> localIds) async =>
      (await deleteLocalAssetsDetailed(localIds)).deletedIds.length;

  Future<LocalDeletionResult> deleteLocalAssetsDetailed(List<String> localIds, {bool trash = true}) async {
    final unique = localIds.toSet().toList();
    final deleted = <String>{};
    for (int index = 0; index < unique.length; index += _deleteBatchSize) {
      final end = index + _deleteBatchSize < unique.length ? index + _deleteBatchSize : unique.length;
      final batch = unique.sublist(index, end);
      final Set<String> acknowledged;
      try {
        acknowledged = (await _assetMediaRepository.deleteAll(batch, trash: trash)).where(batch.contains).toSet();
      } catch (_) {
        // OS denial/network/iCloud failure affects this batch. Never claim all were removed.
        continue;
      }
      if (acknowledged.isNotEmpty) {
        // Remove only OS-acknowledged IDs, including cached Android device
        // Trash rows after permanent cleanup. Cache failures must surface;
        // they are not permission denials or successful completed retries.
        await _localAssetRepository.deleteAssets(acknowledged.toList());
        if (!trash) await _trashedLocalRepository?.deleteAssets(acknowledged.toList());
        deleted.addAll(acknowledged);
      }
    }
    return LocalDeletionResult(
      deletedIds: deleted.toList(),
      remainingIds: unique.where((id) => !deleted.contains(id)).toList(),
    );
  }

  /// Returns album IDs that should be kept by default (e.g., messaging app albums)
  Set<String> getDefaultKeepAlbumIds(List<(String id, String name)> albums) {
    const messagingApps = ['whatsapp', 'telegram', 'signal', 'messenger', 'viber', 'wechat', 'line'];

    final toKeep = <String>{};
    for (final (id, name) in albums) {
      final albumName = name.toLowerCase();
      if (messagingApps.any((app) => albumName.contains(app))) {
        toKeep.add(id);
      }
    }
    return toKeep;
  }
}
