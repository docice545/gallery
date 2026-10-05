import 'package:background_downloader/background_downloader.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/models/download/download_state.model.dart';
import 'package:immich_mobile/platform/live_photo_save_api.g.dart';
import 'package:immich_mobile/services/download.service.dart';
import 'package:logging/logging.dart';

class DownloadStateNotifier extends StateNotifier<DownloadState> {
  final DownloadService _downloadService;
  final Set<String> _dismissedTaskIds = {};

  DownloadStateNotifier(this._downloadService)
    : super(
        const DownloadState(
          downloadStatus: TaskStatus.complete,
          showProgress: false,
          taskProgress: <String, DownloadInfo>{},
        ),
      ) {
    _downloadService.onImageDownloadStatus = _downloadStatusCallback;
    _downloadService.onVideoDownloadStatus = _downloadStatusCallback;
    _downloadService.onLivePhotoDownloadStatus = _downloadStatusCallback;
    _downloadService.onTaskProgress = _taskProgressCallback;
    _downloadService.onLivePhotoSaved = _livePhotoSavedCallback;
  }

  void _downloadStatusCallback(TaskStatusUpdate update) {
    if (!mounted) {
      return;
    }
    if (update.status == TaskStatus.enqueued) {
      _dismissedTaskIds.remove(update.task.taskId);
    }
    if (_dismissedTaskIds.contains(update.task.taskId)) {
      return;
    }
    if (update.status == TaskStatus.canceled) {
      _removeTask(update.task.taskId);
      return;
    }

    final existing =
        state.taskProgress[update.task.taskId] ??
        DownloadInfo(fileName: update.task.filename, progress: 0, status: update.status);

    state = state.copyWith(
      showProgress: true,
      taskProgress: <String, DownloadInfo>{}
        ..addAll(state.taskProgress)
        ..addAll({
          update.task.taskId: existing.copyWith(
            status: update.status,
            progress: update.status == TaskStatus.complete ? 1 : existing.progress,
          ),
        }),
    );
  }

  void _livePhotoSavedCallback(Task task, LivePhotoSaveResult result) {
    if (!mounted || _dismissedTaskIds.contains(task.taskId)) {
      return;
    }
    final existing =
        state.taskProgress[task.taskId] ??
        DownloadInfo(fileName: task.filename, progress: 0, status: TaskStatus.running);
    state = state.copyWith(
      taskProgress: {
        ...state.taskProgress,
        task.taskId: existing.copyWith(livePhotoOutcome: result.outcome),
      },
    );
  }

  void _taskProgressCallback(TaskProgressUpdate update) {
    if (!mounted) {
      return;
    }
    // Ignore if the task is canceled or completed
    final existing = state.taskProgress[update.task.taskId];
    if (!mounted ||
        update.progress < 0 ||
        _dismissedTaskIds.contains(update.task.taskId) ||
        existing?.status == TaskStatus.complete ||
        existing?.status == TaskStatus.failed ||
        existing?.status == TaskStatus.notFound) {
      return;
    }

    state = state.copyWith(
      showProgress: true,
      taskProgress: <String, DownloadInfo>{}
        ..addAll(state.taskProgress)
        ..addAll({
          update.task.taskId: DownloadInfo(
            progress: update.progress,
            fileName: update.task.filename,
            status: TaskStatus.running,
          ),
        }),
    );
  }

  Future<void> cancelDownload(String id) async {
    final status = state.taskProgress[id]?.status;
    if (status == TaskStatus.complete || status == TaskStatus.failed || status == TaskStatus.notFound) {
      _removeTask(id);
      return;
    }
    try {
      final isCanceled = await _downloadService.cancelDownload(id);
      if (isCanceled && mounted) {
        _removeTask(id);
      }
    } catch (error, stack) {
      Logger('DownloadStateNotifier').warning('Unable to cancel the original download', error, stack);
      if (!mounted) {
        return;
      }
      final existing = state.taskProgress[id];
      if (mounted && existing != null) {
        state = state.copyWith(
          taskProgress: {
            ...state.taskProgress,
            id: existing.copyWith(status: TaskStatus.failed),
          },
        );
      }
    }
  }

  void _removeTask(String id) {
    _dismissedTaskIds.add(id);
    final tasks = <String, DownloadInfo>{}
      ..addAll(state.taskProgress)
      ..remove(id);
    state = state.copyWith(taskProgress: tasks, showProgress: tasks.isNotEmpty);
  }

  @override
  void dispose() {
    _downloadService.onImageDownloadStatus = null;
    _downloadService.onVideoDownloadStatus = null;
    _downloadService.onLivePhotoDownloadStatus = null;
    _downloadService.onTaskProgress = null;
    _downloadService.onLivePhotoSaved = null;
    super.dispose();
  }
}

final downloadStateProvider = StateNotifierProvider<DownloadStateNotifier, DownloadState>(
  (ref) => DownloadStateNotifier(ref.watch(downloadServiceProvider)),
  dependencies: [downloadServiceProvider],
);
