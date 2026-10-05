// ignore_for_file: avoid_slow_async_io

import 'dart:io';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/gallery_temporary_cache.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

class StorageRepository {
  final log = Logger('StorageRepository');
  final Future<Directory> Function() _temporaryDirectory;
  final Future<void> Function() _clearPhotoManagerCache;

  StorageRepository({Future<Directory> Function()? temporaryDirectory, Future<void> Function()? clearPhotoManagerCache})
    : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
      _clearPhotoManagerCache = clearPhotoManagerCache ?? PhotoManager.clearFileCache;

  Future<File?> getFileForAsset(String assetId) async {
    File? file;
    final log = Logger('StorageRepository');

    try {
      final entity = await AssetEntity.fromId(assetId);
      file = await entity?.originFile;
      if (file == null) {
        log.warning("Cannot get file for asset $assetId");
        return null;
      }

      final exists = await file.exists();
      if (!exists) {
        log.warning("File for asset $assetId does not exist");
        return null;
      }
    } catch (error, stackTrace) {
      log.warning("Error getting file for asset $assetId", error, stackTrace);
    }
    return file;
  }

  // TODO(agg23): Unify these methods
  Future<File?> getMotionFileForAsset(LocalAsset asset) async {
    File? file;
    final log = Logger('StorageRepository');

    try {
      final entity = await AssetEntity.fromId(asset.id);
      file = await entity?.originFileWithSubtype;
      if (file == null) {
        log.warning(
          "Cannot get motion file for asset ${asset.id}, name: ${asset.name}, created on: ${asset.createdAt}",
        );
        return null;
      }

      final exists = await file.exists();
      if (!exists) {
        log.warning("Motion file for asset ${asset.id} does not exist");
        return null;
      }
    } catch (error, stackTrace) {
      log.warning(
        "Error getting motion file for asset ${asset.id}, name: ${asset.name}, created on: ${asset.createdAt}",
        error,
        stackTrace,
      );
    }
    return file;
  }

  Future<AssetEntity?> getAssetEntityForAsset(LocalAsset asset) async {
    final log = Logger('StorageRepository');

    AssetEntity? entity;

    try {
      entity = await AssetEntity.fromId(asset.id);
      if (entity == null) {
        log.warning(
          "Cannot get AssetEntity for asset ${asset.id}, name: ${asset.name}, created on: ${asset.createdAt}",
        );
      }
    } catch (error, stackTrace) {
      log.warning(
        "Error getting AssetEntity for asset ${asset.id}, name: ${asset.name}, created on: ${asset.createdAt}",
        error,
        stackTrace,
      );
    }
    return entity;
  }

  Future<bool> isAssetAvailableLocally(String assetId, {bool withSubtype = false}) async {
    try {
      final entity = await AssetEntity.fromId(assetId);
      if (entity == null) {
        log.warning("Cannot get AssetEntity for asset $assetId");
        return false;
      }

      return await entity.isLocallyAvailable(isOrigin: true, withSubtype: withSubtype);
    } catch (error, stackTrace) {
      log.warning("Error checking if asset is locally available $assetId", error, stackTrace);
      return false;
    }
  }

  /// Distinguish a removed local ID from an existing PhotoKit item whose original is optimized into iCloud.
  Future<bool> hasMediaLibraryAsset(String assetId) async {
    try {
      return await AssetEntity.fromId(assetId) != null;
    } catch (error, stackTrace) {
      log.warning('Error checking media library asset $assetId', error, stackTrace);
      return false;
    }
  }

  Future<File?> loadFileFromCloud(String assetId, {PMProgressHandler? progressHandler}) async {
    try {
      final entity = await AssetEntity.fromId(assetId);
      if (entity == null) {
        log.warning("Cannot get AssetEntity for asset $assetId");
        return null;
      }

      return await entity.loadFile(progressHandler: progressHandler);
    } catch (error, stackTrace) {
      log.warning("Error loading file from cloud for asset $assetId", error, stackTrace);
      return null;
    }
  }

  Future<File?> loadMotionFileFromCloud(String assetId, {PMProgressHandler? progressHandler}) async {
    try {
      final entity = await AssetEntity.fromId(assetId);
      if (entity == null) {
        log.warning("Cannot get AssetEntity for asset $assetId");
        return null;
      }

      return await entity.loadFile(withSubtype: true, progressHandler: progressHandler);
    } catch (error, stackTrace) {
      log.warning("Error loading motion file from cloud for asset $assetId", error, stackTrace);
      return null;
    }
  }

  Future<void> clearCache() async {
    if (CurrentPlatform.isIOS) {
      // PhotoManager.clearFileCache recursively removes its exported originals
      // (.image/.video/.full) without knowing about active readers. Do not run
      // it here on iOS or delete systemTemp/Library/Caches as a whole.
      try {
        await GalleryTemporaryCache(await _temporaryDirectory()).clear();
      } catch (error, stackTrace) {
        // FileSystemException may include a private resource filename. The
        // exception type and call stack are sufficient to diagnose cleanup.
        log.warning('Error clearing Gallery-owned temporary cache (${error.runtimeType})', null, stackTrace);
      }
      return;
    }

    try {
      await _clearPhotoManagerCache();
    } catch (error, stackTrace) {
      log.warning('Error clearing cache', error, stackTrace);
    }
  }
}
