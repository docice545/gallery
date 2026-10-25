// ignore_for_file: avoid_slow_async_io

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/gallery_temporary_cache.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:uuid/uuid.dart';

class StorageRepository {
  static const _localMotionChannel = MethodChannel('file_trash');
  static final _motionCancelled = Object();
  final log = Logger('StorageRepository');
  final Future<Directory> Function() _temporaryDirectory;
  final Future<void> Function() _clearPhotoManagerCache;

  StorageRepository({Future<Directory> Function()? temporaryDirectory, Future<void> Function()? clearPhotoManagerCache})
    : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
      _clearPhotoManagerCache = clearPhotoManagerCache ?? PhotoManager.clearFileCache;

  /// Resolves a proven device-local video component without contacting a server.
  ///
  /// Android motion JPEG/HEIC files are not videos themselves. The native reader
  /// extracts only their identified embedded video into a bounded private cache
  /// and validates a video track. PhotoManager subtype export remains iOS-only.
  Future<File?> getLocalMotionVideo(LocalAsset asset, {Future<void>? cancellation}) async {
    if (!asset.isImage) {
      return null;
    }
    var cancelled = false;
    final signal = cancellation?.then<Object>((_) {
      cancelled = true;
      return _motionCancelled;
    });
    await Future<void>.value();
    if (cancelled) {
      return null;
    }
    try {
      if (CurrentPlatform.isAndroid) {
        final requestId = const Uuid().v4();
        final request = _localMotionChannel.invokeMethod<String>('localMotionVideo', {
          'requestId': requestId,
          'id': asset.id,
          'name': asset.name,
          'createdAt': asset.createdAt.millisecondsSinceEpoch ~/ 1000,
          'updatedAt': asset.updatedAt.millisecondsSinceEpoch ~/ 1000,
          'checksum': asset.checksum,
        });
        final response = signal == null ? await request : await Future.any<Object?>([request, signal]);
        if (identical(response, _motionCancelled)) {
          try {
            await _localMotionChannel.invokeMethod<bool>('cancelLocalMotionVideo', {'requestId': requestId});
          } finally {
            await request;
          }
          return null;
        }
        if (cancelled || response == null || response is! String || !response.startsWith('/')) {
          return null;
        }
        final file = File(response);
        return await file.exists() && !cancelled ? file : null;
      }
      if (CurrentPlatform.isIOS && await isAssetAvailableLocally(asset.id, withSubtype: true) && !cancelled) {
        final file = await getMotionFileForAsset(asset);
        return cancelled ? null : file;
      }
    } catch (error, stack) {
      if (!cancelled) {
        final code = error is PlatformException ? error.code : error.runtimeType;
        log.warning('Local motion component unavailable ($code)', null, stack);
      }
    }
    return null;
  }

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
