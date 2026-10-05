// ignore_for_file: avoid_slow_async_io

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/models/download/livephotos_medatada.model.dart';
import 'package:immich_mobile/platform/live_photo_save_api.g.dart';
import 'package:immich_mobile/repositories/download.repository.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:logging/logging.dart';

final downloadServiceProvider = Provider((ref) {
  final service = DownloadService(ref.watch(fileMediaRepositoryProvider), ref.watch(downloadRepositoryProvider));
  ref.onDispose(service.dispose);
  return service;
}, dependencies: [fileMediaRepositoryProvider, downloadRepositoryProvider]);

class DownloadService {
  final DownloadRepository _downloadRepository;
  final FileMediaRepository _fileMediaRepository;
  final Logger _log = Logger("DownloadService");
  void Function(TaskStatusUpdate)? onImageDownloadStatus;
  void Function(TaskStatusUpdate)? onVideoDownloadStatus;
  void Function(TaskStatusUpdate)? onLivePhotoDownloadStatus;
  void Function(TaskProgressUpdate)? onTaskProgress;
  void Function(Task, LivePhotoSaveResult)? onLivePhotoSaved;

  /// Active Live Photo IDs undergoing saving
  final Set<String> _savingLivePhotoIds = {};
  final Set<String> _canceledLivePhotoIds = {};
  final Set<String> _savingTaskIds = {};
  final Map<String, String> _livePhotoSaveRequests = {};
  bool _disposed = false;
  Future<void> Function()? onSavedToDevice;

  DownloadService(this._fileMediaRepository, this._downloadRepository) {
    _downloadRepository.onImageDownloadStatus = _onImageDownloadCallback;
    _downloadRepository.onVideoDownloadStatus = _onVideoDownloadCallback;
    _downloadRepository.onLivePhotoDownloadStatus = _onLivePhotoDownloadCallback;
    _downloadRepository.onTaskProgress = _onTaskProgressCallback;
    _downloadRepository.onLivePhotoRecordComplete = (record) => unawaited(
      _onLivePhotoRecordComplete(record).catchError((Object error, StackTrace stack) {
        _log.warning('Unable to save the completed Live Photo', error, stack);
        _downloadRepository.releaseTask(record.task);
        if (!_disposed) {
          onLivePhotoDownloadStatus?.call(TaskStatusUpdate(record.task, TaskStatus.failed));
        }
      }),
    );

    unawaited(
      _savePreviouslyCompletedLivePhotos().catchError((Object error, StackTrace stack) {
        _log.warning('Unable to resume completed Live Photo saves', error, stack);
      }),
    );
  }

  void dispose() {
    _disposed = true;
    _downloadRepository.onImageDownloadStatus = null;
    _downloadRepository.onVideoDownloadStatus = null;
    _downloadRepository.onLivePhotoDownloadStatus = null;
    _downloadRepository.onTaskProgress = null;
    _downloadRepository.onLivePhotoRecordComplete = null;
    onSavedToDevice = null;
    onLivePhotoSaved = null;
  }

  Future<void> _savePreviouslyCompletedLivePhotos() async {
    // Specifically fetch Live Photo video components only, as to not double fetch assets
    final records = await _downloadRepository.getLiveVideoTasks();
    final completedIds = records.map((record) => LivePhotosMetadata.fromJson(record.task.metaData).id).toSet();
    for (final id in completedIds) {
      await _saveLivePhotos(id);
    }
  }

  void _onTaskProgressCallback(TaskProgressUpdate update) {
    if (!_disposed) {
      onTaskProgress?.call(update);
    }
  }

  void _onImageDownloadCallback(TaskStatusUpdate update) {
    if (_disposed) {
      return;
    }
    if (update.status == TaskStatus.complete) {
      unawaited(_saveCompletedTask(update, isVideo: false));
      return;
    }

    onImageDownloadStatus?.call(update);
  }

  void _onVideoDownloadCallback(TaskStatusUpdate update) {
    if (_disposed) {
      return;
    }
    if (update.status == TaskStatus.complete) {
      unawaited(_saveCompletedTask(update, isVideo: true));
      return;
    }

    onVideoDownloadStatus?.call(update);
  }

  void _onLivePhotoDownloadCallback(TaskStatusUpdate update) {
    if (_disposed) {
      return;
    }
    final metadata = LivePhotosMetadata.fromJson(update.task.metaData);
    final id = metadata.id;
    if (update.status == TaskStatus.enqueued && metadata.part == LivePhotosPart.image) {
      _canceledLivePhotoIds.remove(id);
    }
    if (update.status == TaskStatus.canceled ||
        update.status == TaskStatus.failed ||
        update.status == TaskStatus.notFound) {
      if (_canceledLivePhotoIds.add(id)) {
        unawaited(
          _downloadRepository
              .cancelDownload(update.task.taskId, failed: update.status != TaskStatus.canceled)
              .catchError((Object error, StackTrace stack) {
                _log.warning('Unable to cancel the remaining Live Photo component', error, stack);
                return false;
              }),
        );
      }
    }
    if (update.status != TaskStatus.complete) {
      onLivePhotoDownloadStatus?.call(update);
    }
  }

  Future<void> _saveCompletedTask(TaskStatusUpdate update, {required bool isVideo}) async {
    if (!_savingTaskIds.add(update.task.taskId)) {
      return;
    }
    final callback = isVideo ? onVideoDownloadStatus : onImageDownloadStatus;
    callback?.call(TaskStatusUpdate(update.task, TaskStatus.running));
    bool saved = false;
    try {
      saved = isVideo ? await _saveVideo(update.task) : await _saveImageWithPath(update.task);
    } catch (error, stack) {
      _log.warning('Unable to import downloaded media', error, stack);
    } finally {
      _savingTaskIds.remove(update.task.taskId);
      _downloadRepository.releaseTask(update.task);
    }
    if (!_disposed) {
      callback?.call(TaskStatusUpdate(update.task, saved ? TaskStatus.complete : TaskStatus.failed));
      if (saved) {
        await _syncSavedAsset();
      }
    }
  }

  Future<void> _syncSavedAsset() async {
    try {
      await onSavedToDevice?.call();
    } catch (error, stack) {
      _log.warning('Saved media could not be synced yet', error, stack);
    }
  }

  Future<void> _onLivePhotoRecordComplete(TaskRecord record) async {
    final livePhotosId = LivePhotosMetadata.fromJson(record.task.metaData).id;
    await _saveLivePhotos(livePhotosId);
  }

  Future<bool> _saveImageWithPath(Task task) async {
    final filePath = await task.filePath();
    final title = task.filename;
    final relativePath = Platform.isAndroid ? 'DCIM/Immich' : null;
    try {
      final resultAsset = await _fileMediaRepository.saveImageWithFile(
        filePath,
        title: title,
        relativePath: relativePath,
      );
      if (resultAsset != null) {
        _downloadRepository.markSaved(remoteIdForDownloadTask(task), resultAsset.id);
      }
      return resultAsset != null;
    } catch (error, stack) {
      _log.severe("Error saving image", error, stack);
      return false;
    } finally {
      await _deleteTemporaryFile(filePath);
    }
  }

  Future<bool> _saveVideo(Task task) async {
    final filePath = await task.filePath();
    final title = task.filename;
    final relativePath = Platform.isAndroid ? 'DCIM/Immich' : null;
    final file = File(filePath);
    try {
      final resultAsset = await _fileMediaRepository.saveVideo(file, title: title, relativePath: relativePath);
      if (resultAsset != null) {
        _downloadRepository.markSaved(remoteIdForDownloadTask(task), resultAsset.id);
      }
      return resultAsset != null;
    } catch (error, stack) {
      _log.severe("Error saving video", error, stack);
      return false;
    } finally {
      await _deleteTemporaryFile(filePath);
    }
  }

  Future<bool> _saveLivePhotos(String livePhotosId) async {
    if (_disposed) {
      return false;
    }
    final records = await _downloadRepository.getLiveVideoTasks();
    if (_disposed) {
      return false;
    }
    final imageRecord = _findTaskRecord(records, livePhotosId, LivePhotosPart.image);
    final videoRecord = _findTaskRecord(records, livePhotosId, LivePhotosPart.video);

    if (imageRecord == null || videoRecord == null) {
      return false;
    }

    if (_canceledLivePhotoIds.contains(livePhotosId)) {
      return false;
    }

    // Write semaphore for this `livePhotoId`
    if (!_savingLivePhotoIds.add(livePhotosId)) {
      return false;
    }

    final title = imageRecord.task.filename;
    String? imageFilePath;
    String? videoFilePath;
    _savingTaskIds.addAll([imageRecord.task.taskId, videoRecord.task.taskId]);

    bool saved = false;
    LivePhotoSaveOutcome outcome = LivePhotoSaveOutcome.failed;
    _livePhotoSaveRequests[imageRecord.task.taskId] = livePhotosId;
    _livePhotoSaveRequests[videoRecord.task.taskId] = livePhotosId;
    try {
      imageFilePath = await imageRecord.task.filePath();
      videoFilePath = await videoRecord.task.filePath();
      if (_canceledLivePhotoIds.contains(livePhotosId)) {
        outcome = LivePhotoSaveOutcome.cancelled;
        return false;
      }
      final result = await _fileMediaRepository.saveLivePhoto(
        requestId: livePhotosId,
        image: File(imageFilePath),
        video: File(videoFilePath),
        title: title,
      );
      outcome = result.outcome;
      saved = outcome == LivePhotoSaveOutcome.livePhoto || outcome == LivePhotoSaveOutcome.imageOnly;
      if (saved) {
        _downloadRepository.markSaved(livePhotosId, result.localIdentifier!);
      }
      if (!_disposed) {
        for (final record in [imageRecord, videoRecord]) {
          onLivePhotoSaved?.call(record.task, result);
        }
      }
      return saved;
    } catch (error) {
      _log.severe("Error saving live photo (${error.runtimeType})");
      return false;
    } finally {
      if (imageFilePath != null) {
        await _deleteTemporaryFile(imageFilePath);
      }
      if (videoFilePath != null) {
        await _deleteTemporaryFile(videoFilePath);
      }
      try {
        await _downloadRepository.deleteRecordsWithIds([imageRecord.task.taskId, videoRecord.task.taskId]);
      } catch (error, stack) {
        _log.warning('Unable to clean completed Live Photo download records', error, stack);
      }
      _savingTaskIds.removeAll([imageRecord.task.taskId, videoRecord.task.taskId]);
      _savingLivePhotoIds.remove(livePhotosId);
      _livePhotoSaveRequests.remove(imageRecord.task.taskId);
      _livePhotoSaveRequests.remove(videoRecord.task.taskId);
      _downloadRepository.releaseTask(imageRecord.task, afterImport: true);
      if (!_disposed) {
        for (final record in [imageRecord, videoRecord]) {
          onLivePhotoDownloadStatus?.call(
            TaskStatusUpdate(
              record.task,
              saved
                  ? TaskStatus.complete
                  : outcome == LivePhotoSaveOutcome.cancelled
                  ? TaskStatus.canceled
                  : TaskStatus.failed,
            ),
          );
        }
        if (saved) {
          await _syncSavedAsset();
        }
      }
    }
  }

  Future<bool> cancelDownload(String id) async {
    final livePhotoRequest = _livePhotoSaveRequests[id];
    if (livePhotoRequest != null) {
      _canceledLivePhotoIds.add(livePhotoRequest);
      await _fileMediaRepository.cancelLivePhotoSave(livePhotoRequest);
      // The save callback reports the real result. A committed PhotoKit save may still succeed.
      return false;
    }
    // Public platform APIs cannot abort a MediaStore/PhotoKit import after its native transaction begins.
    if (_savingTaskIds.contains(id)) {
      return false;
    }
    return _downloadRepository.cancelDownload(id);
  }

  Future<void> _deleteTemporaryFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error, stack) {
      _log.warning('Unable to clean temporary downloaded original', error, stack);
    }
  }
}

TaskRecord? _findTaskRecord(List<TaskRecord> records, String livePhotosId, LivePhotosPart part) {
  return records.firstWhereOrNull((record) {
    final metadata = LivePhotosMetadata.fromJson(record.task.metaData);
    return metadata.id == livePhotosId && metadata.part == part;
  });
}
