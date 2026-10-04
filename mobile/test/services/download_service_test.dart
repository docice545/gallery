import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/models/download/livephotos_medatada.model.dart';
import 'package:immich_mobile/repositories/download.repository.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:immich_mobile/services/download.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:photo_manager/photo_manager.dart';

class MockDownloadRepository extends Mock implements DownloadRepository {}

class MockFileMediaRepository extends Mock implements FileMediaRepository {}

void main() {
  late MockDownloadRepository repository;
  late MockFileMediaRepository media;
  late DownloadService service;
  late Directory cache;
  late List<TaskRecord> records;
  late void Function(TaskStatusUpdate) onImage;
  late void Function(TaskStatusUpdate) onVideo;
  late void Function(TaskStatusUpdate) onLivePhoto;
  late void Function(TaskRecord) onRecord;
  final entity = AssetEntity(id: '17', typeInt: 1, width: 100, height: 100);

  setUpAll(() {
    registerFallbackValue(File('/temporary'));
    registerFallbackValue(DownloadTask(url: 'https://example.com/original', taskId: 'fallback'));
  });

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('download-service-test-');
    repository = MockDownloadRepository();
    media = MockFileMediaRepository();
    records = [];
    when(() => repository.getLiveVideoTasks()).thenAnswer((_) async => records.toList());
    when(() => repository.deleteRecordsWithIds(any())).thenAnswer((_) async {});
    when(() => repository.cancelDownload(any())).thenAnswer((_) async => true);
    service = DownloadService(media, repository);
    onImage =
        verify(() => repository.onImageDownloadStatus = captureAny()).captured.single
            as void Function(TaskStatusUpdate);
    onVideo =
        verify(() => repository.onVideoDownloadStatus = captureAny()).captured.single
            as void Function(TaskStatusUpdate);
    onLivePhoto =
        verify(() => repository.onLivePhotoDownloadStatus = captureAny()).captured.single
            as void Function(TaskStatusUpdate);
    onRecord =
        verify(() => repository.onLivePhotoRecordComplete = captureAny()).captured.single as void Function(TaskRecord);
  });

  tearDown(() async {
    service.dispose();
    await cache.delete(recursive: true);
  });

  Future<DownloadTask> task(String id, {bool video = false, bool live = false}) async {
    final filename = video ? '$id.MOV' : '$id.jpg';
    await File('${cache.path}/$filename').writeAsBytes([1, 2, 3]);
    return DownloadTask(
      taskId: id,
      url: 'https://example.com/assets/$id/original?edited=false',
      filename: filename,
      directory: cache.path.substring(1),
      baseDirectory: BaseDirectory.root,
      group: live
          ? kDownloadGroupLivePhoto
          : video
          ? kDownloadGroupVideo
          : kDownloadGroupImage,
      metaData: live
          ? LivePhotosMetadata(part: video ? LivePhotosPart.video : LivePhotosPart.image, id: 'live').toJson()
          : '',
    );
  }

  test('server photo becomes a persistent asset before reporting completion and local sync', () async {
    final original = await task('image');
    final save = Completer<AssetEntity?>();
    when(
      () => media.saveImageWithFile(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    ).thenAnswer((_) => save.future);
    final statuses = <TaskStatus>[];
    final finished = Completer<void>();
    service.onImageDownloadStatus = (update) {
      statuses.add(update.status);
      if (update.status == TaskStatus.complete) {
        finished.complete();
      }
    };
    var synced = false;
    service.onSavedToDevice = () async {
      synced = true;
    };
    onImage(TaskStatusUpdate(original, TaskStatus.complete));
    expect(statuses, [TaskStatus.running]);
    expect(synced, isFalse);
    save.complete(entity);
    await finished.future;
    await Future<void>.delayed(Duration.zero);
    expect(statuses, [TaskStatus.running, TaskStatus.complete]);
    verify(() => media.saveImageWithFile('${cache.path}/image.jpg', title: 'image.jpg', relativePath: null)).called(1);
    verify(() => repository.markSaved('image', '17')).called(1);
    expect(synced, isTrue);
    expect(File(await original.filePath()).existsSync(), isFalse);
    verifyNever(
      () => media.saveVideo(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    );
  });

  test('server video uses file-based persistent video save without transcoding', () async {
    final original = await task('video', video: true);
    when(
      () => media.saveVideo(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    ).thenAnswer((_) async => entity);
    final finished = Completer<TaskStatus>();
    service.onVideoDownloadStatus = (update) {
      if (update.status == TaskStatus.complete || update.status == TaskStatus.failed) {
        finished.complete(update.status);
      }
    };
    onVideo(TaskStatusUpdate(original, TaskStatus.complete));
    expect(await finished.future, TaskStatus.complete);
    final file =
        verify(() => media.saveVideo(captureAny(), title: 'video.MOV', relativePath: null)).captured.single as File;
    expect(file.path, '${cache.path}/video.MOV');
    verify(() => repository.markSaved('video', '17')).called(1);
  });

  test('Photos permission/save failure is visible instead of a false download success', () async {
    final original = await task('denied');
    when(
      () => media.saveImageWithFile(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    ).thenThrow(PlatformException(code: 'PERMISSION_DENIED'));
    final finished = Completer<TaskStatus>();
    service.onImageDownloadStatus = (update) {
      if (update.status == TaskStatus.complete || update.status == TaskStatus.failed) {
        finished.complete(update.status);
      }
    };
    onImage(TaskStatusUpdate(original, TaskStatus.complete));
    expect(await finished.future, TaskStatus.failed);
    verifyNever(() => repository.markSaved(any(), any()));
    expect(File(await original.filePath()).existsSync(), isFalse);
  });

  test('network failure never imports an incomplete cache file', () async {
    final original = await task('failed');
    final statuses = <TaskStatus>[];
    service.onImageDownloadStatus = (update) => statuses.add(update.status);
    onImage(TaskStatusUpdate(original, TaskStatus.failed));
    expect(statuses, [TaskStatus.failed]);
    verifyNever(
      () => media.saveImageWithFile(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    );
  });

  test('duplicate completion callbacks do not create two persistent images', () async {
    final original = await task('once');
    final save = Completer<AssetEntity?>();
    when(
      () => media.saveImageWithFile(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    ).thenAnswer((_) => save.future);
    final finished = Completer<void>();
    service.onImageDownloadStatus = (update) {
      if (update.status == TaskStatus.complete) {
        finished.complete();
      }
    };
    onImage(TaskStatusUpdate(original, TaskStatus.complete));
    onImage(TaskStatusUpdate(original, TaskStatus.complete));
    save.complete(entity);
    await finished.future;
    verify(
      () => media.saveImageWithFile(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    ).called(1);
  });

  test('two Apple originals save as one PhotoKit Live Photo with their relationship intact', () async {
    final image = await task('live', live: true);
    final video = await task('motion', video: true, live: true);
    records = [TaskRecord(image, TaskStatus.complete, 1, 3), TaskRecord(video, TaskStatus.complete, 1, 3)];
    when(
      () => media.saveLivePhoto(
        image: any(named: 'image'),
        video: any(named: 'video'),
        title: any(named: 'title'),
      ),
    ).thenAnswer((_) async => entity);
    final statuses = <String, TaskStatus>{};
    final finished = Completer<void>();
    service.onLivePhotoDownloadStatus = (update) {
      statuses[update.task.taskId] = update.status;
      if (statuses.length == 2) {
        finished.complete();
      }
    };
    onLivePhoto(TaskStatusUpdate(image, TaskStatus.complete));
    expect(statuses, isEmpty);
    onRecord(records.first);
    await finished.future;
    expect(statuses, {'live': TaskStatus.complete, 'motion': TaskStatus.complete});
    verify(
      () => media.saveLivePhoto(
        image: any(named: 'image'),
        video: any(named: 'video'),
        title: 'live',
      ),
    ).called(1);
    verifyNever(
      () => media.saveVideo(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    );
    verify(() => repository.markSaved('live', '17')).called(1);
    verify(() => repository.deleteRecordsWithIds(['live', 'motion'])).called(1);
    expect(File(await image.filePath()).existsSync(), isFalse);
    expect(File(await video.filePath()).existsSync(), isFalse);
  });

  test('canceling a Live Photo delegates paired cancellation and does not import either part', () async {
    final image = await task('live', live: true);
    onLivePhoto(TaskStatusUpdate(image, TaskStatus.canceled));
    await Future<void>.delayed(Duration.zero);
    verify(() => repository.cancelDownload('live')).called(1);
    verifyNever(
      () => media.saveLivePhoto(
        image: any(named: 'image'),
        video: any(named: 'video'),
        title: any(named: 'title'),
      ),
    );
  });

  test('a native import already in progress cannot falsely be reported as canceled', () async {
    final original = await task('importing');
    final save = Completer<AssetEntity?>();
    when(
      () => media.saveImageWithFile(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    ).thenAnswer((_) => save.future);
    final finished = Completer<void>();
    service.onImageDownloadStatus = (update) {
      if (update.status == TaskStatus.complete) {
        finished.complete();
      }
    };
    onImage(TaskStatusUpdate(original, TaskStatus.complete));
    expect(await service.cancelDownload(original.taskId), isFalse);
    verifyNever(() => repository.cancelDownload(any()));
    save.complete(entity);
    await finished.future;
  });

  test('opaque download attempt IDs still associate a saved image with the real remote asset', () async {
    final original = (await task(
      'image',
    )).copyWith(taskId: 'remote-image-attempt-1', metaData: json.encode({'id': 'remote-image', 'attempt': '1'}));
    when(
      () => media.saveImageWithFile(
        any(),
        title: any(named: 'title'),
        relativePath: any(named: 'relativePath'),
      ),
    ).thenAnswer((_) async => entity);
    final finished = Completer<void>();
    service.onImageDownloadStatus = (update) {
      if (update.status == TaskStatus.complete) {
        finished.complete();
      }
    };
    onImage(TaskStatusUpdate(original, TaskStatus.complete));
    await finished.future;
    verify(() => repository.markSaved('remote-image', '17')).called(1);
    verifyNever(() => repository.markSaved(original.taskId, any()));
  });
}
