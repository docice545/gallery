import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:logging/logging.dart';

final cleanupServiceProvider = Provider<CleanupService>((ref) {
  return CleanupService(
    ref.watch(driftProvider).localAssetRepository,
    ref.watch(assetMediaRepositoryProvider),
    verifyBackup: ref.watch(assetApiRepositoryProvider).isCleanupBackupAvailable,
  );
});

class CleanupBackupUnverified implements Exception {
  const CleanupBackupUnverified();
}

class CleanupService {
  static final _log = Logger('CleanupService');
  static final int _deleteBatchSize = CurrentPlatform.isAndroid ? 2000 : 10000;

  final LocalAssetRepository _localAssetRepository;
  final AssetMediaRepository _assetMediaRepository;

  final Future<bool> Function(LocalAsset, String)? verifyBackup;
  const CleanupService(this._localAssetRepository, this._assetMediaRepository, {this.verifyBackup});

  Future<void> _verifyBackups(List<LocalAsset> assets, String ownerId) async {
    final verify = verifyBackup;
    if (verify == null) {
      throw const CleanupBackupUnverified();
    }
    // Bound network concurrency even for libraries with thousands of candidates.
    for (var first = 0; first < assets.length; first += 4) {
      final results = await Future.wait(assets.skip(first).take(4).map((asset) => verify(asset, ownerId)));
      if (results.any((verified) => !verified)) {
        throw const CleanupBackupUnverified();
      }
    }
  }

  Future<int> deleteVerifiedLocalAssets(
    List<LocalAsset> assets,
    String ownerId, {
    required bool Function() canContinue,
  }) async {
    final current = <LocalAsset>[];
    for (final asset in assets) {
      final stored = await _localAssetRepository.get(asset.id);
      if (stored == null ||
          stored.checksum != asset.checksum ||
          stored.remoteId != asset.remoteId ||
          stored.isMotionPhoto != asset.isMotionPhoto) {
        throw const CleanupBackupUnverified();
      }
      current.add(stored);
    }
    await _verifyBackups(current, ownerId);
    if (!canContinue()) {
      throw const CleanupBackupUnverified();
    }
    return deleteLocalAssets(current.map((asset) => asset.id).toList());
  }

  Future<RemovalCandidatesResult> getRemovalCandidates(
    String userId,
    DateTime cutoffDate, {
    AssetKeepType keepMediaType = AssetKeepType.none,
    bool keepFavorites = true,
    Set<String> keepAlbumIds = const {},
  }) async {
    final result = await _localAssetRepository.getRemovalCandidates(
      userId,
      cutoffDate,
      keepMediaType: keepMediaType,
      keepFavorites: keepFavorites,
      keepAlbumIds: keepAlbumIds,
    );
    await _verifyBackups(result.assets, userId);
    return result;
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
        final albums = await _localAssetRepository.getAlbumIdsForAssets(acknowledged.toList());
        await _localAssetRepository.deleteAssets(acknowledged.toList());
        deleted.addAll(acknowledged);
        EventStream.shared.emit(DeviceTrashAcknowledgedEvent(albumIds: albums, assetIds: acknowledged));
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
