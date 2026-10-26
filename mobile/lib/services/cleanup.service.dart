import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:logging/logging.dart';

final cleanupServiceProvider = Provider<CleanupService>((ref) {
  return CleanupService(ref.watch(driftProvider).localAssetRepository, ref.watch(assetMediaRepositoryProvider));
});

class CleanupService {
  static final _log = Logger('CleanupService');
  static final int _deleteBatchSize = CurrentPlatform.isAndroid ? 2000 : 10000;

  final LocalAssetRepository _localAssetRepository;
  final AssetMediaRepository _assetMediaRepository;

  const CleanupService(this._localAssetRepository, this._assetMediaRepository);

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
    if (unique.isEmpty) {
      return const LocalDeletionResult(deletedIds: [], remainingIds: []);
    }
    final deleted = <String>{};
    // The verified Android Trash implementation owns its bounded 40-URI
    // requests and cancellation. Splitting a user operation here would let a
    // cancelled system dialog be followed by another outer batch's prompt.
    final batchSize = CurrentPlatform.isAndroid && trash ? unique.length : _deleteBatchSize;
    for (int index = 0; index < unique.length; index += batchSize) {
      final end = index + batchSize < unique.length ? index + batchSize : unique.length;
      final batch = unique.sublist(index, end);
      final Set<String> acknowledged;
      try {
        acknowledged = (await _assetMediaRepository.deleteAll(batch, trash: trash)).where(batch.contains).toSet();
      } on PlatformException catch (error, stack) {
        // Keep every unverified ID selected. A failed native channel must have
        // per-ID diagnostics too, not disappear behind the partial-count toast.
        final code = error.code;
        final reason = (error.message ?? 'No native message')
            .replaceAll(RegExp(r'(?:content|file)://[^\s;]+'), '<media-uri>')
            .replaceAll(RegExp(r'/(?:storage|data|mnt)/[^\s;]+'), '<media-path>');
        for (final id in batch) {
          _log.warning('Device removal id=$id code=$code: $reason; no verified MediaStore result', null, stack);
        }
        continue;
      }
      if (acknowledged.isNotEmpty) {
        // A SQLite failure is not a MediaStore refusal. Propagate it so the
        // caller retains selection and the next verified retry can reconcile
        // an already-trashed row instead of reporting stale cache as success.
        await _localAssetRepository.deleteAssets(acknowledged.toList());
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
