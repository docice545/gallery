import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/models/download/livephotos_medatada.model.dart';
import 'package:immich_mobile/repositories/download.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../unit/factories/remote_asset_factory.dart';
import '../unit/presentation/presentation_context.dart';

class MockDownloader extends Mock implements FileDownloader {}

class MockDownloadDatabase extends Mock implements Database {}

class MockStorage extends Mock implements StorageRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PresentationContext context;
  late MockDownloader downloader;
  late MockDownloadDatabase database;
  late MockStorage storage;
  late StreamController<TaskRecord> records;
  late DownloadRepository repository;
  late List<DownloadTask> enqueued;
  late Map<String, TaskStatusCallback> callbacks;

  setUp(() async {
    context = await PresentationContext.create();
    downloader = MockDownloader();
    database = MockDownloadDatabase();
    storage = MockStorage();
    records = StreamController.broadcast();
    enqueued = [];
    callbacks = {};
    when(() => downloader.database).thenReturn(database);
    when(() => database.updates).thenAnswer((_) => records.stream);
    when(
      () => downloader.registerCallbacks(
        group: any(named: 'group'),
        taskStatusCallback: any(named: 'taskStatusCallback'),
        taskProgressCallback: any(named: 'taskProgressCallback'),
      ),
    ).thenAnswer((invocation) {
      callbacks[invocation.namedArguments[#group] as String] =
          invocation.namedArguments[#taskStatusCallback] as TaskStatusCallback;
      return downloader;
    });
    when(() => downloader.unregisterCallbacks(group: any(named: 'group'))).thenReturn(downloader);
    when(() => downloader.allTasks(allGroups: true)).thenAnswer((_) async => []);
    when(() => downloader.enqueueAll(any())).thenAnswer((invocation) async {
      enqueued.addAll((invocation.positionalArguments.first as Iterable<Task>).cast<DownloadTask>());
      return List.filled((invocation.positionalArguments.first as Iterable<Task>).length, true);
    });
    when(() => storage.isAssetAvailableLocally(any())).thenAnswer((_) async => false);
    when(() => storage.hasMediaLibraryAsset(any())).thenAnswer((_) async => false);
    when(() => downloader.cancelTasksWithIds(any())).thenAnswer((_) async => true);
    when(
      () => database.allRecordsWithStatus(TaskStatus.complete, group: kDownloadGroupLivePhoto),
    ).thenAnswer((_) async => []);
    when(() => database.deleteRecordsWithIds(any())).thenAnswer((_) async {});
    repository = DownloadRepository(downloader: downloader, storageRepository: storage, isAndroid: true);
  });

  tearDown(() async {
    repository.dispose();
    await records.close();
    await context.dispose();
  });

  test('server-only photo and video stream authenticated originals into separate save groups', () async {
    final photo = RemoteAssetFactory.create(name: 'original.HEIC');
    final video = RemoteAssetFactory.create(name: 'movie.mp4', type: AssetType.video);
    expect(await repository.downloadAllAssets([photo, video]), [true, true]);
    expect(enqueued.map((task) => task.group), [kDownloadGroupImage, kDownloadGroupVideo]);
    expect(enqueued.map((task) => task.filename), ['original.HEIC', 'movie.mp4']);
    for (final task in enqueued) {
      expect(task.url, contains('/assets/${remoteIdForDownloadTask(task)}/original?edited=false'));
      expect(task.url, isNot(contains('thumbnail')));
      expect(task.updates, Updates.statusAndProgress);
    }
  });

  test('a real local original avoids another download, but a stale local ID does not', () async {
    final asset = RemoteAssetFactory.create(localId: 'local-id');
    when(() => storage.isAssetAvailableLocally('local-id')).thenAnswer((_) async => true);
    expect(await repository.downloadAllAssets([asset]), isEmpty);
    expect(enqueued, isEmpty);
    when(() => storage.isAssetAvailableLocally('local-id')).thenAnswer((_) async => false);
    expect(await repository.downloadAllAssets([asset]), [true]);
  });

  test('repeated selections do not enqueue an in-flight original twice', () async {
    final asset = RemoteAssetFactory.create();
    await repository.downloadAllAssets([asset, asset]);
    await repository.downloadAllAssets([asset]);
    expect(enqueued, hasLength(1));
  });

  test('a newly saved original is reused before local sync has merged it', () async {
    final asset = RemoteAssetFactory.create();
    repository.markSaved(asset.id, 'saved-local-id');
    when(() => storage.isAssetAvailableLocally('saved-local-id')).thenAnswer((_) async => true);
    expect(await repository.downloadAllAssets([asset]), isEmpty);
    expect(enqueued, isEmpty);
  });

  test('a failed network task releases its reservation for an explicit retry', () async {
    final asset = RemoteAssetFactory.create();
    await repository.downloadAllAssets([asset]);
    callbacks[kDownloadGroupImage]!(TaskStatusUpdate(enqueued.single, TaskStatus.failed));
    await repository.downloadAllAssets([asset]);
    expect(enqueued, hasLength(2));
  });

  test('enqueue failures are surfaced and an explicit retry remains possible', () async {
    final updates = <TaskStatusUpdate>[];
    repository.onImageDownloadStatus = updates.add;
    when(() => downloader.enqueueAll(any())).thenAnswer((_) async => [false]);
    final asset = RemoteAssetFactory.create();
    expect(await repository.downloadAllAssets([asset]), [false]);
    expect(updates.single.status, TaskStatus.failed);
    await repository.downloadAllAssets([asset]);
    expect(updates, hasLength(2));
  });

  test('Android imports only the original still and leaves the server motion pair intact', () async {
    final asset = RemoteAssetFactory.create(name: 'samsung.MP.jpg').copyWith(livePhotoVideoId: 'linked-motion');
    await repository.downloadAllAssets([asset]);
    expect(enqueued, hasLength(1));
    expect(enqueued.single.group, kDownloadGroupImage);
    expect(asset.livePhotoVideoId, 'linked-motion');
  });

  test('iOS enqueues linked originals with one shared Live Photo ID and cancels both parts', () async {
    repository.dispose();
    repository = DownloadRepository(downloader: downloader, storageRepository: storage, isAndroid: false);
    final asset = RemoteAssetFactory.create(name: 'Apple.jpeg').copyWith(livePhotoVideoId: 'paired-mov');
    await repository.downloadAllAssets([asset]);
    expect(enqueued.map((task) => task.filename), ['Apple.jpeg', 'Apple.MOV']);
    expect(enqueued.every((task) => task.group == kDownloadGroupLivePhoto), isTrue);
    final metadata = enqueued.map((task) => LivePhotosMetadata.fromJson(task.metaData)).toList();
    expect(metadata.map((part) => part.id).toSet(), {asset.id});
    expect(metadata.map((part) => part.part).toSet(), LivePhotosPart.values.toSet());
    final ids = enqueued.map((task) => task.taskId).toList();
    expect(await repository.cancelDownload(ids.last), isTrue);
    verify(() => downloader.cancelTasksWithIds(ids)).called(1);
    expect(asset.livePhotoVideoId, 'paired-mov');
  });

  test('unsafe path components are removed while preserving the original extension', () async {
    await repository.downloadAllAssets([RemoteAssetFactory.create(name: '../folder\\original.HEIC')]);
    expect(enqueued.single.filename, 'original.HEIC');
  });

  test('Live Photo retry waits for cancellation acknowledgement and old file/record cleanup', () async {
    repository.dispose();
    repository = DownloadRepository(downloader: downloader, storageRepository: storage, isAndroid: false);
    final asset = RemoteAssetFactory.create(name: 'Apple.HEIC').copyWith(livePhotoVideoId: 'motion');
    await repository.downloadAllAssets([asset]);
    final cancelAck = Completer<bool>();
    final cleanupAck = Completer<void>();
    when(() => downloader.cancelTasksWithIds(any())).thenAnswer((_) => cancelAck.future);
    when(() => database.deleteRecordsWithIds(any())).thenAnswer((_) => cleanupAck.future);
    final oldIds = enqueued.map((task) => task.taskId).toList();
    final cancel = repository.cancelDownload(oldIds.last);
    final duplicateCancel = repository.cancelDownload(asset.id);
    expect(await repository.downloadAllAssets([asset]), isEmpty);
    cancelAck.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(await repository.downloadAllAssets([asset]), isEmpty);
    expect(enqueued, hasLength(2));
    cleanupAck.complete();
    expect(await cancel, isTrue);
    expect(await duplicateCancel, isTrue);
    verify(() => downloader.cancelTasksWithIds(oldIds)).called(1);
    expect(await repository.downloadAllAssets([asset]), [true, true]);
    expect(enqueued, hasLength(4));
  });

  test('an iOS paired enqueue exception cleans partial tasks before permitting retry', () async {
    repository.dispose();
    repository = DownloadRepository(downloader: downloader, storageRepository: storage, isAndroid: false);
    final asset = RemoteAssetFactory.create(name: 'Apple.HEIC').copyWith(livePhotoVideoId: 'motion');
    List<DownloadTask> failedTasks = [];
    when(() => downloader.enqueueAll(any())).thenAnswer((invocation) {
      failedTasks = (invocation.positionalArguments.first as Iterable<Task>).cast<DownloadTask>().toList();
      throw StateError('native enqueue failed after one part');
    });
    await expectLater(repository.downloadAllAssets([asset]), throwsStateError);
    final ids = failedTasks.map((task) => task.taskId).toList();
    verify(() => downloader.cancelTasksWithIds(ids)).called(1);
    verify(() => database.deleteRecordsWithIds(ids)).called(1);
    when(() => downloader.enqueueAll(any())).thenAnswer((invocation) async {
      enqueued.addAll((invocation.positionalArguments.first as Iterable<Task>).cast<DownloadTask>());
      return [true, true];
    });
    expect(await repository.downloadAllAssets([asset]), [true, true]);
    expect(enqueued, hasLength(2));
  });

  test(
    'late canceled callbacks and complete records from an old Apple attempt cannot cancel or pair with a retry',
    () async {
      repository.dispose();
      repository = DownloadRepository(downloader: downloader, storageRepository: storage, isAndroid: false);
      final asset = RemoteAssetFactory.create(name: 'Apple.HEIC').copyWith(livePhotoVideoId: 'motion');
      await repository.downloadAllAssets([asset]);
      final oldTasks = enqueued.toList();
      await repository.cancelDownload(oldTasks.last.taskId);
      await repository.downloadAllAssets([asset]);
      final newTasks = enqueued.skip(2).toList();
      expect(oldTasks.first.taskId, isNot(newTasks.first.taskId));
      expect(oldTasks.first.directory, isNot(newTasks.first.directory));
      final statuses = <TaskStatusUpdate>[];
      final completedRecords = <TaskRecord>[];
      repository.onLivePhotoDownloadStatus = statuses.add;
      repository.onLivePhotoRecordComplete = completedRecords.add;
      callbacks[kDownloadGroupLivePhoto]!(TaskStatusUpdate(oldTasks.first, TaskStatus.canceled));
      records.add(TaskRecord(oldTasks.first, TaskStatus.complete, 1, 3));
      await Future<void>.delayed(Duration.zero);
      expect(statuses, isEmpty);
      expect(completedRecords, isEmpty);
      when(() => database.allRecordsWithStatus(TaskStatus.complete, group: kDownloadGroupLivePhoto)).thenAnswer(
        (_) async => [
          TaskRecord(oldTasks.first, TaskStatus.complete, 1, 3),
          TaskRecord(newTasks.last, TaskStatus.complete, 1, 3),
        ],
      );
      final current = await repository.getLiveVideoTasks();
      expect(current.map((record) => record.taskId), [newTasks.last.taskId]);
    },
  );

  test('different originals with the same filename use distinct temporary cache paths', () async {
    await repository.downloadAllAssets([
      RemoteAssetFactory.create(name: 'IMG_0001.JPG'),
      RemoteAssetFactory.create(name: 'IMG_0001.JPG'),
    ]);
    expect(enqueued.map((task) => task.filename).toSet(), {'IMG_0001.JPG'});
    expect(enqueued.map((task) => task.directory).toSet(), hasLength(2));
    expect(enqueued.every((task) => task.baseDirectory == BaseDirectory.temporary), isTrue);
  });

  test('enqueue failure before a native task exists permits retry even when native cancel returns false', () async {
    final asset = RemoteAssetFactory.create();
    when(() => downloader.enqueueAll(any())).thenThrow(StateError('native enqueue failed before creating a task'));
    when(() => downloader.cancelTasksWithIds(any())).thenAnswer((_) async => false);
    await expectLater(repository.downloadAllAssets([asset]), throwsStateError);
    when(() => downloader.enqueueAll(any())).thenAnswer((invocation) async {
      enqueued.addAll((invocation.positionalArguments.first as Iterable<Task>).cast<DownloadTask>());
      return [true];
    });
    expect(await repository.downloadAllAssets([asset]), [true]);
    expect(enqueued, hasLength(1));
  });

  test('an existing optimized PhotoKit item is preserved while a deleted local ID downloads the original', () async {
    repository.dispose();
    repository = DownloadRepository(downloader: downloader, storageRepository: storage, isAndroid: false);
    final asset = RemoteAssetFactory.create(localId: 'photo-kit-id');
    when(() => storage.hasMediaLibraryAsset('photo-kit-id')).thenAnswer((_) async => true);
    expect(await repository.downloadAllAssets([asset]), isEmpty);
    when(() => storage.hasMediaLibraryAsset('photo-kit-id')).thenAnswer((_) async => false);
    expect(await repository.downloadAllAssets([asset]), [true]);
    expect(enqueued.single.url, contains('/original?edited=false'));
  });

  test('a canceled video attempt cannot release or import a retry through late callbacks', () async {
    final asset = RemoteAssetFactory.create(name: 'movie.mp4', type: AssetType.video);
    await repository.downloadAllAssets([asset]);
    final oldTask = enqueued.single;
    await repository.cancelDownload(asset.id);
    await repository.downloadAllAssets([asset]);
    final current = enqueued.last;
    expect(oldTask.directory, isNot(current.directory));
    final statuses = <TaskStatusUpdate>[];
    repository.onVideoDownloadStatus = statuses.add;
    callbacks[kDownloadGroupVideo]!(TaskStatusUpdate(oldTask, TaskStatus.failed));
    callbacks[kDownloadGroupVideo]!(TaskStatusUpdate(oldTask, TaskStatus.complete));
    expect(statuses, isEmpty);
    expect(await repository.downloadAllAssets([asset]), isEmpty);
    callbacks[kDownloadGroupVideo]!(TaskStatusUpdate(current, TaskStatus.running));
    expect(statuses.single.task.directory, current.directory);
  });

  test('a late retired completion cleans only its old cached file and record', () async {
    final cache = await Directory.systemTemp.createTemp('retired-download-test-');
    addTearDown(() => cache.delete(recursive: true));
    final asset = RemoteAssetFactory.create(name: 'movie.mp4', type: AssetType.video);
    await repository.downloadAllAssets([asset]);
    final old = enqueued.single.copyWith(
      baseDirectory: BaseDirectory.root,
      directory: '${cache.path.substring(1)}/old',
    );
    final oldFile = File(await old.filePath());
    await oldFile.parent.create(recursive: true);
    await oldFile.writeAsBytes([1, 2, 3]);
    await repository.cancelDownload(old.taskId);
    await repository.downloadAllAssets([asset]);
    final currentFile = await File('${cache.path}/current.mp4').writeAsBytes([4, 5, 6]);
    final cleaned = Completer<void>();
    when(() => database.deleteRecordsWithIds([old.taskId])).thenAnswer((_) async {
      cleaned.complete();
    });
    callbacks[kDownloadGroupVideo]!(TaskStatusUpdate(old, TaskStatus.complete));
    await cleaned.future;
    expect(oldFile.existsSync(), isFalse);
    expect(currentFile.existsSync(), isTrue);
    expect(await repository.downloadAllAssets([asset]), isEmpty);
  });
}
