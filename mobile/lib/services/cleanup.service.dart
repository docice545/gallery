import 'dart:async';

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
    backupApi: ref.watch(assetApiRepositoryProvider),
  );
});

class CleanupService {
  static final _log = Logger('CleanupService');
  static final int _deleteBatchSize = CurrentPlatform.isAndroid ? 2000 : 10000;

  final LocalAssetRepository _localAssetRepository;
  final AssetMediaRepository _assetMediaRepository;

  final AssetApiRepository? backupApi;
  const CleanupService(this._localAssetRepository, this._assetMediaRepository, {this.backupApi});

  Future<LocalDeletionResult> deleteVerifiedBackups(
    List<LocalAsset> snapshot,
    String userId,
    DateTime cutoffDate, {
    required bool Function() canContinue,
    AssetKeepType keepMediaType = AssetKeepType.none,
    bool keepFavorites = true,
    Set<String> keepAlbumIds = const {},
  }) async {
    final requested = {for (final asset in snapshot) asset.id: asset};
    final deleted = <String>{};
    LocalDeletionResult result() => LocalDeletionResult(
      deletedIds: deleted.toList(),
      remainingIds: requested.keys.where((id) => !deleted.contains(id)).toList(),
    );
    if (requested.isEmpty || !canContinue()) {
      return result();
    }
    final api = backupApi;
    if (api == null) {
      throw StateError('Backup verifier is unavailable');
    }
    final fresh = await getRemovalCandidates(
      userId,
      cutoffDate,
      keepMediaType: keepMediaType,
      keepFavorites: keepFavorites,
      keepAlbumIds: keepAlbumIds,
    );
    if (!canContinue()) {
      return result();
    }
    final eligible = fresh.assets.where((asset) {
      final original = requested[asset.id];
      return original != null &&
          original.checksum == asset.checksum &&
          original.remoteId == asset.remoteId &&
          original.updatedAt == asset.updatedAt &&
          original.adjustmentTime == asset.adjustmentTime &&
          original.playbackStyle == asset.playbackStyle;
    }).toList();
    // Verify a bounded batch immediately before the existing native operation.
    // An OS denial/partial receipt stops the outer loop; it cannot open another
    // confirmation or silently retry failed IDs.
    for (var offset = 0; offset < eligible.length; offset += 40) {
      if (!canContinue()) {
        break;
      }
      final batch = eligible.skip(offset).take(40).toList();
      final watch = Stopwatch()..start();
      final verified = <LocalAsset>[];
      try {
        for (var start = 0; start < batch.length; start += 4) {
          if (!canContinue()) {
            return result();
          }
          final group = batch.skip(start).take(4).toList();
          final checks = await Future.wait(
            group.map(
              (asset) => api
                  .hasVerifiedBackup(asset, userId, keepFavorites: keepFavorites)
                  .timeout(const Duration(seconds: 15)),
            ),
          );
          for (var i = 0; i < checks.length; i++) {
            if (checks[i]) {
              verified.add(group[i]);
            }
          }
        }
        // Recheck all exclusions after the network wait, including newly added
        // album membership, remote tombstones and local edits.
        final currentCandidates = await getRemovalCandidates(
          userId,
          cutoffDate,
          keepMediaType: keepMediaType,
          keepFavorites: keepFavorites,
          keepAlbumIds: keepAlbumIds,
        );
        final currentById = {for (final asset in currentCandidates.assets) asset.id: asset};
        for (final asset in verified.toList()) {
          final current = currentById[asset.id];
          if (current == null ||
              current.checksum != asset.checksum ||
              current.remoteId != asset.remoteId ||
              current.updatedAt != asset.updatedAt ||
              current.adjustmentTime != asset.adjustmentTime ||
              current.playbackStyle != asset.playbackStyle ||
              (keepFavorites && current.isFavorite)) {
            verified.remove(asset);
          }
        }
      } catch (_) {
        break; // No network/verification failure grants permission to remove a file.
      }
      if (!canContinue() || watch.elapsed > const Duration(seconds: 30)) {
        break;
      }
      if (verified.isEmpty) {
        continue;
      }
      final receipt = await deleteLocalAssetsDetailed(verified.map((a) => a.id).toList());
      deleted.addAll(receipt.deletedIds);
      if (receipt.remainingIds.isNotEmpty) {
        break;
      }
    }
    return result();
  }

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
