import 'package:background_downloader/background_downloader.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/models/download/livephotos_medatada.model.dart';
import 'package:immich_mobile/providers/asset_viewer/download.provider.dart';
import 'package:immich_mobile/services/download.service.dart';
import 'package:mocktail/mocktail.dart';

class MockDownloadService extends Mock implements DownloadService {}

DownloadTask _task(String id, {String filename = 'photo.jpg', String metaData = ''}) =>
    DownloadTask(taskId: id, url: 'https://example.com/$filename', filename: filename, metaData: metaData);

void main() {
  late MockDownloadService service;
  late DownloadStateNotifier notifier;
  late void Function(TaskProgressUpdate) onProgress;
  late void Function(TaskStatusUpdate) onImage;
  late void Function(TaskStatusUpdate) onLivePhoto;

  setUp(() {
    service = MockDownloadService();
    notifier = DownloadStateNotifier(service);
    addTearDown(() {
      if (notifier.mounted) {
        notifier.dispose();
      }
    });

    onProgress = verify(() => service.onTaskProgress = captureAny()).captured.last as void Function(TaskProgressUpdate);
    onImage =
        verify(() => service.onImageDownloadStatus = captureAny()).captured.last as void Function(TaskStatusUpdate);
    onLivePhoto =
        verify(() => service.onLivePhotoDownloadStatus = captureAny()).captured.last as void Function(TaskStatusUpdate);
  });

  test('complete flips the entry and keeps it visible', () {
    fakeAsync((async) {
      final task = _task('task-1');
      onProgress(TaskProgressUpdate(task, 0.4));
      onImage(TaskStatusUpdate(task, TaskStatus.complete));

      expect(notifier.state.taskProgress['task-1']?.status, TaskStatus.complete);
      expect(notifier.state.showProgress, isTrue);

      async.elapse(const Duration(seconds: 5));

      expect(notifier.state.taskProgress['task-1']?.status, TaskStatus.complete);
      expect(notifier.state.showProgress, isTrue);
    });
  });

  test('failed keeps the entry visible', () {
    fakeAsync((async) {
      final task = _task('task-1');
      onProgress(TaskProgressUpdate(task, 0.4));
      onImage(TaskStatusUpdate(task, TaskStatus.failed));

      expect(notifier.state.taskProgress['task-1']?.status, TaskStatus.failed);

      async.elapse(const Duration(seconds: 5));

      expect(notifier.state.taskProgress['task-1']?.status, TaskStatus.failed);
      expect(notifier.state.showProgress, isTrue);
    });
  });

  test('a live photo part completion keeps both entries', () {
    fakeAsync((async) {
      final image = _task(
        'live-image',
        metaData: const LivePhotosMetadata(part: LivePhotosPart.image, id: 'live-1').toJson(),
      );
      final video = _task(
        'live-video',
        filename: 'photo.MOV',
        metaData: const LivePhotosMetadata(part: LivePhotosPart.video, id: 'live-1').toJson(),
      );
      onProgress(TaskProgressUpdate(image, 0.9));
      onProgress(TaskProgressUpdate(video, 0.9));
      onLivePhoto(TaskStatusUpdate(image, TaskStatus.complete));

      async.elapse(const Duration(seconds: 5));

      expect(notifier.state.taskProgress['live-image']?.status, TaskStatus.complete);
      expect(notifier.state.taskProgress['live-video']?.status, TaskStatus.running);
      expect(notifier.state.showProgress, isTrue);
    });
  });

  test('canceled removes the entry and late progress does not resurrect it', () {
    fakeAsync((async) {
      final task = _task('task-1');
      onProgress(TaskProgressUpdate(task, 0.4));
      onImage(TaskStatusUpdate(task, TaskStatus.canceled));

      expect(notifier.state.taskProgress.containsKey('task-1'), isFalse);
      expect(notifier.state.showProgress, isFalse);
      onProgress(TaskProgressUpdate(task, 0.6));
      expect(notifier.state.taskProgress.containsKey('task-1'), isFalse);

      onImage(TaskStatusUpdate(_task('ghost'), TaskStatus.canceled));
      expect(notifier.state.taskProgress.containsKey('ghost'), isFalse);
    });
  });

  test('fast tasks report completion even when the downloader never sends progress', () {
    fakeAsync((async) {
      onImage(TaskStatusUpdate(_task('ghost'), TaskStatus.complete));

      expect(notifier.state.taskProgress['ghost']?.status, TaskStatus.complete);
      expect(notifier.state.taskProgress['ghost']?.progress, 1);
      expect(notifier.state.showProgress, isTrue);
    });
  });

  test('a network failure before progress is visible and cannot be overwritten by late progress', () {
    final task = _task('network-failed');
    onImage(TaskStatusUpdate(task, TaskStatus.failed));
    onProgress(TaskProgressUpdate(task, 0.5));
    expect(notifier.state.taskProgress[task.taskId]?.status, TaskStatus.failed);
    expect(notifier.state.showProgress, isTrue);
  });

  test('complete entries can be dismissed without canceling a finished native download', () async {
    final task = _task('complete');
    onImage(TaskStatusUpdate(task, TaskStatus.complete));
    await notifier.cancelDownload(task.taskId);
    expect(notifier.state.taskProgress, isEmpty);
    expect(notifier.state.showProgress, isFalse);
    verifyNever(() => service.cancelDownload(any()));
    onProgress(TaskProgressUpdate(task, 0.9));
    expect(notifier.state.taskProgress, isEmpty);
  });

  test('queued retry of a canceled task resets its suppression', () {
    final task = _task('retry');
    onImage(TaskStatusUpdate(task, TaskStatus.canceled));
    onImage(TaskStatusUpdate(task, TaskStatus.enqueued));
    onProgress(TaskProgressUpdate(task, 0.2));
    expect(notifier.state.taskProgress[task.taskId]?.status, TaskStatus.running);
  });
}
