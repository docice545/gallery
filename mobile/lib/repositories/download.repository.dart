import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/models/download/livephotos_medatada.model.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final downloadRepositoryProvider = Provider((ref) {
  final repository = DownloadRepository(storageRepository: ref.watch(storageRepositoryProvider));
  ref.onDispose(repository.dispose);
  return repository;
}, dependencies: [storageRepositoryProvider]);

/// Attempts have unique task IDs while metadata retains the existing Gallery asset ID.
/// Older persisted tasks still use the remote ID as their task ID.
String remoteIdForDownloadTask(Task task) {
  if (task.metaData.isEmpty) {
    return task.taskId;
  }
  final metadata = json.decode(task.metaData) as Map<String, dynamic>;
  return metadata['id'] as String? ?? task.taskId;
}

class DownloadRepository {
  final FileDownloader _downloader;
  final StorageRepository _storageRepository;
  final bool _isAndroid;
  final Set<String> _pendingAssetIds = {};
  final Map<String, String> _savedAssetIds = {};
  final Map<String, Set<String>> _livePhotoTaskIds = {};
  final Map<String, List<DownloadTask>> _livePhotoTasks = {};
  final Set<String> _cancelingAssetIds = {};
  final Map<String, Future<bool>> _cancellations = {};
  final Map<String, String> _ordinaryTaskDirectories = {};
  final Map<String, DownloadTask> _ordinaryTasks = {};
  final Set<String> _retiredOrdinaryDirectories = {};
  final Set<String> _retiredOrdinaryTaskIds = {};
  final Set<String> _retiredLivePhotoTaskIds = {};
  final Set<String> _cleaningStaleTaskIds = {};
  int _nextAttempt = 0;
  final _log = Logger('DownloadRepository');
  late final StreamSubscription<TaskRecord> _livePhotoSubscription;

  void Function(TaskStatusUpdate)? onImageDownloadStatus;
  void Function(TaskStatusUpdate)? onVideoDownloadStatus;
  void Function(TaskStatusUpdate)? onLivePhotoDownloadStatus;
  void Function(TaskProgressUpdate)? onTaskProgress;

  // Records are observed after the downloader DB update, so two Live Photo parts cannot race.
  void Function(TaskRecord)? onLivePhotoRecordComplete;

  DownloadRepository({FileDownloader? downloader, StorageRepository? storageRepository, bool? isAndroid})
    : _downloader = downloader ?? FileDownloader(),
      _storageRepository = storageRepository ?? StorageRepository(),
      _isAndroid = isAndroid ?? Platform.isAndroid {
    for (final group in [kDownloadGroupImage, kDownloadGroupVideo, kDownloadGroupLivePhoto]) {
      _downloader.registerCallbacks(
        group: group,
        taskStatusCallback: (update) {
          if (group == kDownloadGroupLivePhoto && !_isCurrentLivePhotoTask(update.task)) {
            if (update.status == TaskStatus.complete) {
              unawaited(_cleanupStaleTask(update.task));
            }
            return;
          }
          if (group != kDownloadGroupLivePhoto && !_isCurrentOrdinaryTask(update.task)) {
            if (update.status == TaskStatus.complete) {
              unawaited(_cleanupStaleTask(update.task));
            }
            return;
          }
          if (update.status == TaskStatus.failed ||
              update.status == TaskStatus.notFound ||
              update.status == TaskStatus.canceled) {
            releaseTask(update.task);
          }
          switch (group) {
            case kDownloadGroupImage:
              onImageDownloadStatus?.call(update);
            case kDownloadGroupVideo:
              onVideoDownloadStatus?.call(update);
            case kDownloadGroupLivePhoto:
              onLivePhotoDownloadStatus?.call(update);
          }
        },
        taskProgressCallback: (update) {
          if (group == kDownloadGroupLivePhoto
              ? _isCurrentLivePhotoTask(update.task)
              : _isCurrentOrdinaryTask(update.task)) {
            onTaskProgress?.call(update);
          }
        },
      );
    }
    _livePhotoSubscription = _downloader.database.updates
        .where((record) {
          if (record.group != kDownloadGroupLivePhoto || record.status != TaskStatus.complete) {
            return false;
          }
          if (!_isCurrentLivePhotoTask(record.task)) {
            unawaited(_cleanupStaleTask(record.task));
            return false;
          }
          return true;
        })
        .listen((record) => onLivePhotoRecordComplete?.call(record));
  }

  void dispose() {
    unawaited(_livePhotoSubscription.cancel());
    for (final group in [kDownloadGroupImage, kDownloadGroupVideo, kDownloadGroupLivePhoto]) {
      _downloader.unregisterCallbacks(group: group);
    }
  }

  Future<void> _cleanupStaleTask(Task task) async {
    if (!_cleaningStaleTaskIds.add(task.taskId)) {
      return;
    }
    try {
      final file = File(await task.filePath());
      if (file.existsSync()) {
        await file.delete();
      }
      await deleteRecordsWithIds([task.taskId]);
    } catch (error, stack) {
      _log.warning('Unable to clean a retired original download attempt', error, stack);
    } finally {
      _cleaningStaleTaskIds.remove(task.taskId);
    }
  }

  bool _isCurrentLivePhotoTask(Task task) {
    if (_retiredLivePhotoTaskIds.contains(task.taskId)) {
      return false;
    }
    final id = LivePhotosMetadata.fromJson(task.metaData).id;
    final current = _livePhotoTasks[id];
    return current == null || current.any((currentTask) => currentTask.taskId == task.taskId);
  }

  bool _isCurrentOrdinaryTask(Task task) =>
      !_retiredOrdinaryTaskIds.contains(task.taskId) &&
      !_retiredOrdinaryDirectories.contains(task.directory) &&
      (_ordinaryTaskDirectories[remoteIdForDownloadTask(task)] == null ||
          _ordinaryTaskDirectories[remoteIdForDownloadTask(task)] == task.directory);

  Future<List<TaskRecord>> getLiveVideoTasks() async {
    final records = await _downloader.database.allRecordsWithStatus(
      TaskStatus.complete,
      group: kDownloadGroupLivePhoto,
    );
    final current = records.where((record) => _isCurrentLivePhotoTask(record.task)).toList();
    // Resume only one attempt per asset after a restart; never pair an older still with a retry's video.
    final newest = <String, TaskRecord>{};
    for (final record in current) {
      final id = LivePhotosMetadata.fromJson(record.task.metaData).id;
      if (newest[id] == null || record.task.creationTime.isAfter(newest[id]!.task.creationTime)) {
        newest[id] = record;
      }
    }
    return current.where((record) {
      final metadata = json.decode(record.task.metaData) as Map<String, dynamic>;
      final latest = json.decode(newest[metadata['id']]!.task.metaData) as Map<String, dynamic>;
      return metadata['attempt'] == latest['attempt'];
    }).toList();
  }

  Future<void> deleteRecordsWithIds(List<String> ids) => _downloader.database.deleteRecordsWithIds(ids);

  void markSaved(String remoteId, String localId) {
    _savedAssetIds[remoteId] = localId;
    final directory = _ordinaryTaskDirectories[remoteId];
    if (directory != null) {
      _retiredOrdinaryDirectories.add(directory);
    }
    final ordinary = _ordinaryTasks[remoteId];
    if (ordinary != null) {
      _retiredOrdinaryTaskIds.add(ordinary.taskId);
    }
    _pendingAssetIds.remove(remoteId);
    _retiredLivePhotoTaskIds.addAll(_livePhotoTaskIds.remove(remoteId) ?? {});
    _livePhotoTasks.remove(remoteId);
  }

  void releaseTask(Task task, {bool afterImport = false}) {
    final id = remoteIdForDownloadTask(task);
    if (task.group == kDownloadGroupLivePhoto && !afterImport) {
      return;
    }
    _pendingAssetIds.remove(id);
    if (afterImport) {
      _retiredLivePhotoTaskIds.addAll(_livePhotoTaskIds.remove(id) ?? {});
      _livePhotoTasks.remove(id);
    }
  }

  Future<List<bool>> downloadAllAssets(List<RemoteAsset> assets) async {
    final tasks = <DownloadTask>[];
    final headers = ApiService.getRequestHeaders();
    final activeIds = (await _downloader.allTasks(allGroups: true))
        .map(
          (task) => [kDownloadGroupLivePhoto, kDownloadGroupImage, kDownloadGroupVideo].contains(task.group)
              ? remoteIdForDownloadTask(task)
              : task.taskId,
        )
        .toSet();
    for (final asset in assets) {
      final id = asset.id;
      if (_pendingAssetIds.contains(id) || _cancelingAssetIds.contains(id) || activeIds.contains(id)) {
        continue;
      }
      // Merged assets can carry a stale ID after freeing phone storage. This check does not fetch iCloud originals.
      final localId = _savedAssetIds[id] ?? asset.localId;
      if (localId != null && await _storageRepository.isAssetAvailableLocally(localId)) {
        continue;
      }
      // Existing PhotoKit items remain managed by Apple, including optimized iCloud originals.
      // Re-importing their Gallery bytes would duplicate the same item in Photos.
      if (!_isAndroid && localId != null && await _storageRepository.hasMediaLibraryAsset(localId)) {
        continue;
      }
      // Reserve after the async lookup because another selection may enqueue the same asset meanwhile.
      if (!_pendingAssetIds.add(id)) {
        continue;
      }
      _savedAssetIds.remove(id);
      final attempt = '${DateTime.now().microsecondsSinceEpoch}-${_nextAttempt++}';
      final directory = 'device-downloads/$id/$attempt';
      final filename = p.basename(asset.name.replaceAll('\\', '/')).replaceAll(RegExp(r'[\x00-\x1f]'), '_');
      final safeFilename = filename.isEmpty || filename == '.' || filename == '..' ? id : filename;
      final livePhotoVideoId = asset.livePhotoVideoId;
      // Preserve Samsung embedded motion bytes; never import its extracted video as a second media item.
      final isAndroidMotionPhoto = asset.name.toUpperCase().contains('.MP');
      if (_isAndroid || livePhotoVideoId == null || asset.isVideo || isAndroidMotionPhoto) {
        _ordinaryTaskDirectories[id] = directory;
        tasks.add(
          DownloadTask(
            taskId: '$id-$attempt',
            url: getOriginalUrlForRemoteId(id, edited: false),
            headers: headers,
            filename: safeFilename,
            directory: directory,
            baseDirectory: BaseDirectory.temporary,
            updates: Updates.statusAndProgress,
            group: asset.isVideo ? kDownloadGroupVideo : kDownloadGroupImage,
            metaData: json.encode({'id': id, 'attempt': attempt}),
          ),
        );
        _ordinaryTasks[id] = tasks.last;
        continue;
      }
      final partTaskIds = <String>{};
      for (final part in [LivePhotosPart.image, LivePhotosPart.video]) {
        final isImage = part == LivePhotosPart.image;
        final partId = isImage ? id : livePhotoVideoId;
        final taskId = '$partId-$attempt';
        partTaskIds.add(taskId);
        tasks.add(
          DownloadTask(
            taskId: taskId,
            url: getOriginalUrlForRemoteId(partId, edited: false),
            headers: headers,
            filename: isImage ? safeFilename : '${p.basenameWithoutExtension(safeFilename)}.MOV',
            directory: directory,
            baseDirectory: BaseDirectory.temporary,
            updates: Updates.statusAndProgress,
            group: kDownloadGroupLivePhoto,
            metaData: json.encode({'part': part.index, 'id': id, 'attempt': attempt}),
          ),
        );
      }
      _livePhotoTaskIds[id] = partTaskIds;
      _livePhotoTasks[id] = tasks.sublist(tasks.length - 2);
    }
    if (tasks.isEmpty) {
      return const [];
    }
    try {
      final results = await _downloader.enqueueAll(tasks);
      for (var index = 0; index < tasks.length; index++) {
        if (index >= results.length || !results[index]) {
          final task = tasks[index];
          releaseTask(task);
          final update = TaskStatusUpdate(task, TaskStatus.failed);
          switch (task.group) {
            case kDownloadGroupImage:
              onImageDownloadStatus?.call(update);
            case kDownloadGroupVideo:
              onVideoDownloadStatus?.call(update);
            case kDownloadGroupLivePhoto:
              onLivePhotoDownloadStatus?.call(update);
          }
        }
      }
      return results;
    } catch (_) {
      // Native enqueue can fail after accepting one part. Wait for cancellation/cleanup before allowing the same IDs again.
      final ids = tasks.map(remoteIdForDownloadTask).toSet();
      for (final id in ids) {
        try {
          await cancelDownload(id, failed: true);
        } catch (error, stack) {
          _log.warning('Unable to clean a partially enqueued original download', error, stack);
        }
      }
      rethrow;
    }
  }

  Future<bool> cancelDownload(String id, {bool failed = false}) {
    final pair = _livePhotoTaskIds.entries.where((entry) => entry.key == id || entry.value.contains(id)).firstOrNull;
    final ordinary = _ordinaryTasks.entries.where((entry) => entry.key == id || entry.value.taskId == id).firstOrNull;
    final assetId = pair?.key ?? ordinary?.key ?? id;
    final existing = _cancellations[assetId];
    if (existing != null) {
      return existing;
    }
    // Register before native cancellation can synchronously deliver a callback.
    final completion = Completer<bool>();
    _cancellations[assetId] = completion.future;
    unawaited(
      _cancelAsset(
        assetId,
        pair?.value ?? {ordinary?.value.taskId ?? id},
        failed: failed,
      ).then(completion.complete, onError: completion.completeError),
    );
    return completion.future.whenComplete(() => _cancellations.remove(assetId));
  }

  Future<bool> _cancelAsset(String assetId, Set<String> ids, {required bool failed}) async {
    _cancelingAssetIds.add(assetId);
    try {
      final result = await _downloader.cancelTasksWithIds(ids.toList());
      if (!result) {
        // Native enqueue may throw before creating any task, in which case there is nothing left to cancel.
        final active = await _downloader.allTasks(allGroups: true);
        if (active.any((task) => ids.contains(task.taskId))) {
          return false;
        }
      }
      if (ids.length > 1) {
        final records = await getLiveVideoTasks();
        for (final record in records.where((record) => ids.contains(record.taskId))) {
          try {
            final file = File(await record.task.filePath());
            if (file.existsSync()) {
              await file.delete();
            }
          } catch (error, stack) {
            _log.warning('Unable to clean canceled Live Photo file', error, stack);
          }
        }
        await deleteRecordsWithIds(ids.toList());
        for (final task in _livePhotoTasks[assetId] ?? <DownloadTask>[]) {
          onLivePhotoDownloadStatus?.call(TaskStatusUpdate(task, failed ? TaskStatus.failed : TaskStatus.canceled));
        }
        _retiredLivePhotoTaskIds.addAll(_livePhotoTaskIds.remove(assetId) ?? {});
        _livePhotoTasks.remove(assetId);
      }
      final directory = _ordinaryTaskDirectories[assetId];
      if (directory != null) {
        _retiredOrdinaryDirectories.add(directory);
      }
      _retiredOrdinaryTaskIds.addAll(ids);
      _pendingAssetIds.remove(assetId);
      return true;
    } finally {
      _cancelingAssetIds.remove(assetId);
    }
  }
}
