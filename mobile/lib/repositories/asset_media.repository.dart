// ignore_for_file: avoid_slow_async_io

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/live_photo_api.g.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/utils/original_file.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

/// A file staged for the share sheet. [tempEntity] is the temp file or
/// directory retained for receivers. Completed share files expire after seven days.
typedef _ShareFile = ({File file, FileSystemEntity? tempEntity, String displayName});

enum LivePhotoShareMode { preserveMotion, imageOnly }

final assetMediaRepositoryProvider = Provider(
  (ref) => AssetMediaRepository(
    ref.watch(nativeSyncApiProvider),
    ref.watch(storageRepositoryProvider),
    remoteAssetById: ref.watch(driftProvider).remoteAssetRepository.get,
  ),
);

class AssetMediaRepository {
  final NativeSyncApi _nativeSyncApi;
  final StorageRepository _storageRepository;
  static final Logger _log = Logger("AssetMediaRepository");
  static const shareRetention = Duration(days: 7);
  static const _shareChannel = MethodChannel('app.alextran.immich/originalShare');
  static Future<void> _shareWorkTail = Future<void>.value();
  final LivePhotoApi? livePhotoApi;
  final Future<RemoteAsset?> Function(String)? remoteAssetById;

  const AssetMediaRepository(this._nativeSyncApi, this._storageRepository, {this.livePhotoApi, this.remoteAssetById});

  Future<bool> _androidSupportsTrash() async {
    if (Platform.isAndroid) {
      final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
      final AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      final int sdkVersion = androidInfo.version.sdkInt;
      return sdkVersion >= 31;
    }
    return false;
  }

  Future<List<String>> deleteAll(List<String> ids, {bool trash = true}) async {
    if (trash && CurrentPlatform.isAndroid && await _androidSupportsTrash()) {
      return PhotoManager.editor.android.moveToTrash(
        ids.map((e) => AssetEntity(id: e, width: 1, height: 1, typeInt: 0)).toList(),
      );
    }
    return PhotoManager.editor.deleteWithIds(ids);
  }

  Future<bool> _restoreFromTrashById(String mediaId, int type) async {
    try {
      return await _nativeSyncApi.restoreFromTrashById(mediaId, type);
    } catch (e, s) {
      _log.warning('Error restore file from trash by Id', e, s);
      return false;
    }
  }

  Future<List<String>> restoreAssetsFromTrash(Iterable<LocalAsset> assets) async {
    final restoredIds = <String>[];
    for (final asset in assets) {
      _log.info("Restoring from trash, localId: ${asset.id}, checksum: ${asset.checksum}");
      final result = await _restoreFromTrashById(asset.id, asset.type.index);
      if (result) {
        restoredIds.add(asset.id);
      }
    }
    return restoredIds;
  }

  Future<String?> getOriginalFilename(String id) async {
    final entity = await AssetEntity.fromId(id);
    if (entity == null) {
      return null;
    }

    try {
      // titleAsync gets the correct original filename for some assets on iOS
      // otherwise using the `entity.title` would return a random GUID
      final originalFilename = await entity.titleAsync;
      // treat empty filename as missing
      return originalFilename.isNotEmpty ? originalFilename : null;
    } catch (e) {
      _log.warning("Failed to get original filename for asset: $id. Error: $e");
      return null;
    }
  }

  @protected
  @visibleForTesting
  Future<void> cleanupTempFiles(List<FileSystemEntity> tempFiles) async {
    await Future.wait(
      tempFiles.map((file) async {
        try {
          if (file.existsSync()) {
            await file.delete(recursive: true);
          }
        } catch (e) {
          _log.warning("Failed to delete an owned temporary file");
        }
      }),
    );
  }

  static final RegExp _pathSeparators = RegExp(r'[\\/]');

  static String _sanitizeFilename(String filename) {
    final safe = filename.replaceAll(RegExp(r'[\\/\x00-\x1f\x7f]'), '_');
    return safe == '.' || safe == '..' ? 'asset' : safe;
  }

  static String _getOriginalShareFilename(BaseAsset asset) {
    final hasUsableName = asset.name.replaceAll(_pathSeparators, '').isNotEmpty;
    return hasUsableName ? _sanitizeFilename(asset.name) : _shareFallbackName(asset);
  }

  static String _shareFallbackName(BaseAsset asset) => asset.remoteId ?? asset.localId ?? 'asset';

  static String _getPreviewFilename(BaseAsset asset) {
    final sanitizedFilename = _sanitizeFilename(asset.name);
    final baseName = p.basenameWithoutExtension(sanitizedFilename);
    return '${baseName.isEmpty ? _shareFallbackName(asset) : baseName}-preview.jpg';
  }

  static String _shareDisplayName(BaseAsset asset, ShareAssetType fileType) =>
      switch (asset.isVideo ? ShareAssetType.original : fileType) {
        ShareAssetType.original => _getOriginalShareFilename(asset),
        ShareAssetType.preview => _getPreviewFilename(asset),
      };

  static String _ordinalShareFilename(String filename, int occurrence) =>
      '${p.basenameWithoutExtension(filename)} ($occurrence)${p.extension(filename)}';

  bool _isCancelled(Completer<void>? cancelCompleter) => cancelCompleter?.isCompleted ?? false;

  Future<Directory> _shareRoot() async {
    final root = Directory(p.join((await getTemporaryDirectory()).path, 'outgoing_share'));
    await root.create(recursive: true);
    return root;
  }

  /// A chooser result means a target was selected, not that it finished reading.
  /// Keep completed files through subsequent shares; purge only old directories.
  @visibleForTesting
  Future<void> cleanupExpiredShareFiles({DateTime? now}) async {
    final root = await _shareRoot();
    final cutoff = (now ?? DateTime.now()).subtract(shareRetention);
    final expired = <FileSystemEntity>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory) {
        final marker = File(p.join(entity.path, '.complete'));
        final modified = (await (marker.existsSync() ? marker.stat() : entity.stat())).modified;
        if (modified.isBefore(cutoff)) {
          expired.add(entity);
        }
      }
    }
    await cleanupTempFiles(expired);
  }

  Future<File?> _cachedShareFile(Directory directory, String displayName) async {
    final file = File(p.join(directory.path, displayName));
    if (!File(p.join(directory.path, '.complete')).existsSync() || !file.existsSync()) {
      return null;
    }
    if (await file.length() == 0) {
      return null;
    }
    await File(p.join(directory.path, '.complete')).setLastModified(DateTime.now());
    return file;
  }

  Future<void> _completeShareFile(File file, {String? mimeType}) async {
    await File(p.join(file.parent.path, '.complete')).writeAsString(jsonEncode({'mimeType': mimeType}), flush: true);
  }

  Future<_ShareFile?> _getLocalOriginalShareFile(BaseAsset asset, String localId, String displayName) async {
    final file = await _storageRepository.getFileForAsset(localId);
    if (file == null || !file.existsSync() || await file.length() == 0) {
      _log.warning("Local original file not found for sharing: $asset");
      return null;
    }
    final stat = await file.stat();
    final key = const Uuid().v5(Namespace.url.value, 'local|$localId|${stat.modified}|${stat.size}|$displayName');
    final directory = Directory(p.join((await _shareRoot()).path, key));
    var staged = await _cachedShareFile(directory, displayName);
    if (staged == null) {
      await directory.create(recursive: true);
      staged = await file.copy(p.join(directory.path, displayName));
      await _completeShareFile(staged);
    }
    // Never rename/delete a library original or PhotoManager's own exported file.
    return (file: staged, tempEntity: directory, displayName: displayName);
  }

  Future<_ShareFile?> _downloadRemoteShareFile({
    required String taskId,
    required String url,
    required String displayName,
    Completer<void>? cancelCompleter,
    required void Function(double progress) onProgress,
  }) async {
    final key = const Uuid().v5(Namespace.url.value, '$url|$taskId|$displayName');
    final directory = Directory(p.join((await _shareRoot()).path, key));
    final cached = await _cachedShareFile(directory, displayName);
    if (cached != null) {
      onProgress(1);
      return (file: cached, tempEntity: directory, displayName: displayName);
    }
    final task = DownloadTask(
      taskId: 'share-$key',
      url: url,
      headers: ApiService.getRequestHeaders(),
      filename: displayName,
      directory: 'outgoing_share/$key',
      baseDirectory: BaseDirectory.temporary,
      group: kShareDownloadGroup,
      updates: Updates.statusAndProgress,
    );
    final downloader = FileDownloader();
    var finished = false;
    final cancellations = <Future<bool>>[];
    void cancelTask() {
      if (!finished) {
        final cancellation = downloader.cancelTaskWithId(task.taskId).catchError((Object error, StackTrace stack) {
          _log.warning('Unable to cancel original download', error, stack);
          return false;
        });
        cancellations.add(cancellation);
        unawaited(cancellation);
      }
    }

    // Cancel independently of progress: offline/stalled requests may emit none.
    if (cancelCompleter != null) {
      unawaited(cancelCompleter.future.then((_) => cancelTask()));
    }
    try {
      final statusUpdate = await downloader.download(
        task,
        onStatus: (status) {
          if (_isCancelled(cancelCompleter) && (status == TaskStatus.enqueued || status == TaskStatus.running)) {
            cancelTask();
          }
        },
        onProgress: (value) {
          if (!_isCancelled(cancelCompleter) && value >= 0) {
            onProgress(value);
          }
        },
      );
      final file = File(await task.filePath());
      if (!_isCancelled(cancelCompleter) &&
          statusUpdate.status == TaskStatus.complete &&
          file.existsSync() &&
          await file.length() > 0) {
        await _completeShareFile(file, mimeType: statusUpdate.mimeType);
        return (file: file, tempEntity: file.parent, displayName: displayName);
      }
      await cleanupTempFiles([directory]);
      if (!_isCancelled(cancelCompleter)) {
        _log.severe("Download for $displayName failed with status ${statusUpdate.status}", statusUpdate.exception);
      }
      return null;
    } catch (error, stack) {
      await cleanupTempFiles([directory]);
      _log.warning('Original download failed', error, stack);
      return null;
    } finally {
      finished = true;
      await Future.wait(cancellations);
    }
  }

  Future<_ShareFile?> _getRemoteOriginalShareFile(
    BaseAsset asset,
    String remoteId, {
    required String displayName,
    Completer<void>? cancelCompleter,
    required void Function(double progress) onProgress,
  }) {
    return _downloadRemoteShareFile(
      taskId: 'original-$remoteId-${asset.updatedAt.microsecondsSinceEpoch}',
      url: getOriginalUrlForRemoteId(remoteId, edited: false),
      displayName: displayName,
      cancelCompleter: cancelCompleter,
      onProgress: onProgress,
    );
  }

  Future<_ShareFile?> _getRemotePreviewShareFile(
    BaseAsset asset,
    String remoteId, {
    required String displayName,
    Completer<void>? cancelCompleter,
    required void Function(double progress) onProgress,
  }) {
    return _downloadRemoteShareFile(
      taskId: 'preview-$remoteId-${asset.updatedAt.microsecondsSinceEpoch}',
      url: getThumbnailUrlForRemoteId(remoteId, type: AssetMediaSize.preview, edited: asset.isEdited),
      displayName: displayName,
      cancelCompleter: cancelCompleter,
      onProgress: onProgress,
    );
  }

  Future<_ShareFile?> _getOriginalShareFile(
    BaseAsset asset, {
    required String displayName,
    Completer<void>? cancelCompleter,
    required void Function(double progress) onProgress,
  }) async {
    final localId = asset.localId;
    if (localId != null && (asset.remoteId == null || await _storageRepository.isAssetAvailableLocally(localId))) {
      final localFile = await _getLocalOriginalShareFile(asset, localId, displayName);
      if (localFile != null || _isCancelled(cancelCompleter)) {
        return localFile;
      }
      // A freed/deleted original can outlive its local ID in the sync cache.
    }

    final remoteId = asset.remoteId;
    if (remoteId == null) {
      _log.warning("Asset has no remote ID for sharing: $asset");
      return Future.value(null);
    }

    return _getRemoteOriginalShareFile(
      asset,
      remoteId,
      displayName: displayName,
      cancelCompleter: cancelCompleter,
      onProgress: onProgress,
    );
  }

  Future<_ShareFile?> _getPreviewShareFile(
    BaseAsset asset, {
    required String displayName,
    Completer<void>? cancelCompleter,
    required void Function(double progress) onProgress,
  }) async {
    final remoteId = asset.remoteId;
    if (remoteId != null) {
      final remotePreview = await _getRemotePreviewShareFile(
        asset,
        remoteId,
        displayName: displayName,
        cancelCompleter: cancelCompleter,
        onProgress: onProgress,
      );
      if (remotePreview != null || asset.isEdited) {
        return remotePreview;
      }
    }

    final localId = asset.localId;
    if (localId != null) {
      return _getLocalOriginalShareFile(asset, localId, _shareDisplayName(asset, ShareAssetType.original));
    }

    _log.warning("Asset has no local or remote ID for preview sharing: $asset");
    return null;
  }

  /// Preserve cache originals and provide distinct display names in a batch.
  Future<void> _resolveShareFiles(List<_ShareFile> files) async {
    final usedNames = <String>{};
    for (var index = 0; index < files.length; index++) {
      final shareFile = files[index];
      var occurrence = 0;
      var displayName = shareFile.displayName;
      while (usedNames.contains(displayName)) {
        displayName = _ordinalShareFilename(shareFile.displayName, ++occurrence);
      }
      usedNames.add(displayName);
      if (displayName == shareFile.displayName) {
        continue;
      }
      final directory = Directory(p.join((await _shareRoot()).path, const Uuid().v4()));
      await directory.create();
      final file = await shareFile.file.copy(p.join(directory.path, displayName));
      await _completeShareFile(file, mimeType: await _shareMimeType(shareFile.file));
      files[index] = (file: file, tempEntity: directory, displayName: displayName);
    }
  }

  Future<String> _shareMimeType(File file) async {
    final marker = File(p.join(file.parent.path, '.complete'));
    String? serverMimeType;
    if (marker.existsSync()) {
      try {
        final metadata = jsonDecode(await marker.readAsString());
        if (metadata is Map<String, dynamic> && metadata['mimeType'] is String) {
          serverMimeType = metadata['mimeType'] as String;
        }
      } catch (_) {
        // A crash/OS eviction can truncate optional metadata. The original's
        // bounded header/filename remain usable; do not poison future shares.
      }
    }
    return originalFileMimeType(file, fallback: serverMimeType);
  }

  Future<int> shareAssets(
    List<BaseAsset> assets,
    BuildContext context, {
    ShareAssetType fileType = ShareAssetType.original,
    LivePhotoShareMode livePhotoMode = LivePhotoShareMode.preserveMotion,
    Completer<void>? cancelCompleter,
    void Function(double progress)? onAssetDownloadProgress,
  }) async {
    // Cancellation closes the UI immediately, but native cleanup may still be
    // running. Serialize preparation so a retry cannot reuse that active task
    // ID or delete files while another preparation is writing them.
    final previous = _shareWorkTail;
    final finished = Completer<void>();
    _shareWorkTail = finished.future;
    try {
      await previous;
      if (_isCancelled(cancelCompleter) || !context.mounted) {
        return 0;
      }
      return await _prepareAndShareAssets(
        assets,
        context,
        fileType: fileType,
        livePhotoMode: livePhotoMode,
        cancelCompleter: cancelCompleter,
        onAssetDownloadProgress: onAssetDownloadProgress,
      );
    } finally {
      finished.complete();
    }
  }

  Future<int> _prepareAndShareAssets(
    List<BaseAsset> assets,
    BuildContext context, {
    ShareAssetType fileType = ShareAssetType.original,
    LivePhotoShareMode livePhotoMode = LivePhotoShareMode.preserveMotion,
    Completer<void>? cancelCompleter,
    void Function(double progress)? onAssetDownloadProgress,
  }) async {
    final shareFiles = <_ShareFile>[];
    final motionFiles = <String, String>{};
    await cleanupExpiredShareFiles();
    final totalAssets = assets.length;
    var processedAssets = 0;

    void updateProgress([double currentAssetProgress = 0.0]) {
      if (totalAssets <= 0) {
        onAssetDownloadProgress?.call(1.0);
        return;
      }

      final normalizedAssetProgress = currentAssetProgress.clamp(0.0, 1.0);
      final overallProgress = ((processedAssets + normalizedAssetProgress) / totalAssets).clamp(0.0, 1.0);
      onAssetDownloadProgress?.call(overallProgress);
    }

    updateProgress();

    for (final asset in assets) {
      if (_isCancelled(cancelCompleter)) {
        return 0;
      }

      final effectiveFileType = asset.isVideo ? ShareAssetType.original : fileType;
      final displayName = _shareDisplayName(asset, fileType);

      if (CurrentPlatform.isIOS &&
          asset.isMotionPhoto &&
          effectiveFileType == ShareAssetType.original &&
          livePhotoMode == LivePhotoShareMode.preserveMotion) {
        final pair = await _getLivePhotoSharePair(asset, cancelCompleter: cancelCompleter, onProgress: updateProgress);
        if (pair == null || _isCancelled(cancelCompleter)) {
          // The requested transfer must not silently lose motion. The explicit
          // image-only action can be chosen after this preparation error.
          return 0;
        }
        shareFiles.add((file: File(pair.imagePath), tempEntity: File(pair.imagePath).parent, displayName: displayName));
        motionFiles[pair.imagePath] = pair.videoPath;
        processedAssets++;
        updateProgress();
        continue;
      }

      final shareFile = switch (effectiveFileType) {
        ShareAssetType.original => await _getOriginalShareFile(
          asset,
          displayName: displayName,
          cancelCompleter: cancelCompleter,
          onProgress: updateProgress,
        ),
        ShareAssetType.preview => await _getPreviewShareFile(
          asset,
          displayName: displayName,
          cancelCompleter: cancelCompleter,
          onProgress: updateProgress,
        ),
      };

      if (_isCancelled(cancelCompleter)) {
        return 0;
      }

      if (shareFile == null) {
        processedAssets++;
        updateProgress();
        continue;
      }

      shareFiles.add(shareFile);
      processedAssets++;
      updateProgress();
    }

    if (shareFiles.isEmpty) {
      _log.warning("No asset can be retrieved for share");
      return 0;
    }

    if (_isCancelled(cancelCompleter) || !context.mounted) {
      return 0;
    }

    try {
      if (motionFiles.isEmpty) {
        await _resolveShareFiles(shareFiles);
      }
    } catch (e, s) {
      _log.warning("Failed to prepare files for sharing", e, s);
      return 0;
    }
    if (_isCancelled(cancelCompleter) || !context.mounted) {
      return 0;
    }
    final downloadedXFiles = <XFile>[];
    for (final shareFile in shareFiles) {
      downloadedXFiles.add(XFile(shareFile.file.path, mimeType: await _shareMimeType(shareFile.file)));
    }
    if (_isCancelled(cancelCompleter) || !context.mounted) {
      return 0;
    }
    final size = context.sizeData;
    if (CurrentPlatform.isAndroid) {
      await _shareChannel.invokeMethod<bool>('shareFiles', {
        'paths': downloadedXFiles.map((file) => file.path).toList(),
        'mimeTypes': downloadedXFiles.map((file) => file.mimeType).toList(),
        'displayNames': shareFiles.map((file) => file.displayName).toList(),
      });
    } else if (CurrentPlatform.isIOS && motionFiles.isNotEmpty) {
      final api = livePhotoApi ?? LivePhotoApi();
      var finished = false;
      if (cancelCompleter != null) {
        unawaited(
          cancelCompleter.future.then((_) async {
            if (!finished) {
              try {
                await api.cancelLivePhotoShare();
              } catch (_) {}
            }
          }),
        );
      }
      try {
        final shared = await api.shareLivePhotos(
          [
            for (final file in shareFiles)
              LivePhotoShareItem(imagePath: file.file.path, videoPath: motionFiles[file.file.path]),
          ],
          0,
          0,
          size.width / 3,
          size.height,
        );
        return shared && !_isCancelled(cancelCompleter) ? shareFiles.length : 0;
      } finally {
        finished = true;
      }
    } else {
      // iOS completion likewise does not prove the receiver has finished reading.
      unawaited(
        Share.shareXFiles(
          downloadedXFiles,
          sharePositionOrigin: Rect.fromPoints(Offset.zero, Offset(size.width / 3, size.height)),
        ).catchError((Object error, StackTrace stack) {
          _log.warning('System share failed', error, stack);
          return ShareResult.unavailable;
        }),
      );
    }

    return downloadedXFiles.length;
  }

  Future<LivePhotoResourcePair?> _getLivePhotoSharePair(
    BaseAsset asset, {
    Completer<void>? cancelCompleter,
    required void Function(double) onProgress,
  }) async {
    final api = livePhotoApi ?? LivePhotoApi();
    final localId = asset.localId;
    if (localId != null && await _storageRepository.hasMediaLibraryAsset(localId)) {
      var finished = false;
      if (cancelCompleter != null) {
        unawaited(
          cancelCompleter.future.then((_) async {
            if (!finished) {
              try {
                await api.cancelLivePhotoExport(localId);
              } catch (_) {}
            }
          }),
        );
      }
      try {
        // Cancellation requests PhotoKit cancellation. Await the export future:
        // writers close/drain before native failure cleanup or returning paths.
        final pair = await api.exportLivePhoto(localId);
        if (pair != null || _isCancelled(cancelCompleter)) {
          return _isCancelled(cancelCompleter) ? null : pair;
        }
      } finally {
        finished = true;
      }
    }
    final remote = asset is RemoteAsset
        ? asset
        : asset.remoteId != null
        ? await remoteAssetById?.call(asset.remoteId!)
        : null;
    if (remote?.livePhotoVideoId == null || _isCancelled(cancelCompleter)) {
      return null;
    }
    final still = await _getOriginalShareFile(
      asset,
      displayName: _getOriginalShareFilename(asset),
      cancelCompleter: cancelCompleter,
      onProgress: (value) => onProgress(value / 2),
    );
    if (still == null || _isCancelled(cancelCompleter)) {
      return null;
    }
    final motion = await _downloadRemoteShareFile(
      taskId: 'live-motion-${remote!.livePhotoVideoId}-${asset.updatedAt.microsecondsSinceEpoch}',
      url: getOriginalUrlForRemoteId(remote.livePhotoVideoId!, edited: false),
      displayName: '${p.basenameWithoutExtension(_getOriginalShareFilename(asset))}.mov',
      cancelCompleter: cancelCompleter,
      onProgress: (value) => onProgress(0.5 + value / 2),
    );
    if (motion == null || _isCancelled(cancelCompleter)) {
      return null;
    }
    // Retain both members in one owned directory; cleanup never deletes half a
    // requested Apple pair. Neither source original is modified or saved to Photos.
    final key = const Uuid().v5(Namespace.url.value, 'apple-pair|${still.file.path}|${motion.file.path}');
    final directory = Directory(p.join((await _shareRoot()).path, key));
    final imageName = _getOriginalShareFilename(asset);
    final cachedImage = await _cachedShareFile(directory, imageName);
    final cachedVideo = File(p.join(directory.path, 'motion.mov'));
    if (cachedImage != null && cachedVideo.existsSync() && cachedVideo.lengthSync() > 0) {
      return LivePhotoResourcePair(imagePath: cachedImage.path, videoPath: cachedVideo.path);
    }
    await directory.create();
    try {
      final image = await still.file.copy(p.join(directory.path, imageName));
      final video = await motion.file.copy(p.join(directory.path, 'motion.mov'));
      await _completeShareFile(image);
      return LivePhotoResourcePair(imagePath: image.path, videoPath: video.path);
    } catch (_) {
      await cleanupTempFiles([directory]);
      return null;
    }
  }
}
