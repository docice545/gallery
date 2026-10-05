import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/live_photo_api.g.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;

import '../test_utils.dart';

class _MockNativeSyncApi extends Mock implements NativeSyncApi {}

class _MockLivePhotoApi extends Mock implements LivePhotoApi {}

class _MockPersistentStorage extends Mock implements PersistentStorage {}

class _MockStorageRepository extends Mock implements StorageRepository {}

class _TestAssetMediaRepository extends AssetMediaRepository {
  _TestAssetMediaRepository(super.nativeSyncApi, super.storageRepository, {super.livePhotoApi, super.remoteAssetById});

  final cleanups = <List<FileSystemEntity>>[];

  @override
  Future<void> cleanupTempFiles(List<FileSystemEntity> tempFiles) async {
    cleanups.add(tempFiles);
    await super.cleanupTempFiles(tempFiles);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Drift db;
  late StoreService store;
  late Directory tempRoot;
  late _MockStorageRepository storage;
  late _MockNativeSyncApi nativeSync;
  late _TestAssetMediaRepository repository;
  late List<DownloadTask> downloads;
  late Set<String> failedRemoteIds;
  late Set<String> stalledRemoteIds;
  late Map<String, List<int>> remoteBytes;
  late Map<String, String> responseMimeTypes;
  late List<String> cancelledTaskIds;
  late List<MethodCall> mediaLibraryCalls;
  late List<Map<Object?, Object?>> sharedArguments;
  late Completer<Map<Object?, Object?>> shareCall;
  void Function(DownloadTask)? onTaskStarted;
  Future<void> Function()? afterCancellationStatus;

  setUpAll(() async {
    tempRoot = Directory.systemTemp.createTempSync('immich-share-test');
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await SettingsRepository.ensureInitialized(db);
    await Store.put(StoreKey.serverEndpoint, 'https://example.com/api');
    // Keep the native downloader's persistent store inside this test process.
    final persistentStorage = _MockPersistentStorage();
    when(persistentStorage.initialize).thenAnswer((_) async {});
    when(() => persistentStorage.removeResumeData(any())).thenAnswer((_) async {});
    when(() => persistentStorage.removePausedTask(any())).thenAnswer((_) async {});
    when(persistentStorage.retrieveAllPausedTasks).thenAnswer((_) async => []);
    await FileDownloader(persistentStorage: persistentStorage).ready;
  });

  tearDownAll(() async {
    await SettingsRepository.reset();
    await store.dispose();
    await db.close();
  });

  setUp(() {
    tempRoot.createSync(recursive: true);
    storage = _MockStorageRepository();
    when(() => storage.isAssetAvailableLocally(any())).thenAnswer((_) async => true);
    nativeSync = _MockNativeSyncApi();
    repository = _TestAssetMediaRepository(nativeSync, storage);
    downloads = [];
    failedRemoteIds = {};
    stalledRemoteIds = {};
    remoteBytes = {};
    responseMimeTypes = {};
    cancelledTaskIds = [];
    mediaLibraryCalls = [];
    sharedArguments = [];
    shareCall = Completer<Map<Object?, Object?>>();
    onTaskStarted = null;
    afterCancellationStatus = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tempRoot.path,
    );
    Future<Object?> captureShare(MethodCall call) async {
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      sharedArguments.add(arguments);
      if (!shareCall.isCompleted) {
        shareCall.complete(arguments);
      }
      return call.method == 'shareFiles' && sharedArguments.last.containsKey('displayNames') ? true : 'success';
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('app.alextran.immich/originalShare'),
      captureShare,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/share'),
      captureShare,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.fluttercandies/photo_manager'),
      (call) async {
        mediaLibraryCalls.add(call);
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.bbflight.background_downloader'),
      (call) async {
        if (call.method == 'cancelTasksWithIds') {
          final ids = (call.arguments as List).cast<String>();
          cancelledTaskIds.addAll(ids);
          for (final task in downloads.where((task) => ids.contains(task.taskId))) {
            FileDownloader().downloaderForTesting.processStatusUpdate(TaskStatusUpdate(task, TaskStatus.canceled));
          }
          await afterCancellationStatus?.call();
          return true;
        }
        if (call.method != 'enqueue') {
          return true;
        }
        final args = call.arguments! as List;
        final task = Task.createFromJsonString(args.first as String) as DownloadTask;
        downloads.add(task);
        final id = Uri.parse(task.url).pathSegments[2];
        final file = File(await task.filePath());
        await file.parent.create(recursive: true);
        await file.writeAsBytes(remoteBytes[id] ?? [0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
        onTaskStarted?.call(task);
        if (stalledRemoteIds.contains(id)) {
          // No progress/status arrives until the user's independent cancellation.
          return true;
        }
        FileDownloader().downloaderForTesting.processProgressUpdate(TaskProgressUpdate(task, 0.5));
        final status = failedRemoteIds.contains(id) ? TaskStatus.failed : TaskStatus.complete;
        FileDownloader().downloaderForTesting.processStatusUpdate(
          TaskStatusUpdate(task, status, null, null, null, null, responseMimeTypes[id]),
        );
        return true;
      },
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<({int count, List<String> names, List<String> paths, List<String> mimeTypes})> share(
    WidgetTester tester,
    List<BaseAsset> assets, {
    ShareAssetType fileType = ShareAssetType.original,
    Completer<void>? cancelCompleter,
    TargetPlatform platform = TargetPlatform.android,
    void Function(double)? onProgress,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final result = await tester.runAsync(() async {
      shareCall = Completer<Map<Object?, Object?>>();
      final count = await repository.shareAssets(
        assets,
        context,
        fileType: fileType,
        cancelCompleter: cancelCompleter,
        onAssetDownloadProgress: onProgress,
      );
      // A failed/cancelled operation never opens a share sheet.
      if (count == 0) {
        return (count: count, names: <String>[], paths: <String>[], mimeTypes: <String>[]);
      }
      final arguments = await shareCall.future;
      final paths = (arguments['paths']! as List).cast<String>();
      return (
        count: count,
        names: paths.map(p.basename).toList(),
        paths: paths,
        mimeTypes: (arguments['mimeTypes']! as List).cast<String>(),
      );
    });
    debugDefaultTargetPlatformOverride = null;
    return result!;
  }

  File localFile(String basename, List<int> bytes) {
    final file = File(p.join(tempRoot.path, 'local', basename));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file;
  }

  Future<BuildContext> mountShareContext(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return context;
  }

  testWidgets('iOS server pair shares original still and motion as one native item and reuses retained bytes', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final api = _MockLivePhotoApi();
    final batches = <List<LivePhotoShareItem>>[];
    when(() => api.shareLivePhotos(any(), any(), any(), any(), any())).thenAnswer((invocation) async {
      batches.add(invocation.positionalArguments.first as List<LivePhotoShareItem>);
      return true;
    });
    repository = _TestAssetMediaRepository(nativeSync, storage, livePhotoApi: api);
    final context = await mountShareContext(tester);
    final asset = TestUtils.createRemoteAsset(
      id: 'apple-still',
    ).copyWith(name: 'photo.heic', livePhotoVideoId: 'apple-motion');
    try {
      await tester.runAsync(() async {
        expect(await repository.shareAssets([asset], context), 1);
        expect(await repository.shareAssets([asset], context), 1);
      });
      expect(downloads, hasLength(2));
      expect(downloads.every((task) => task.url.contains('/original?edited=false')), isTrue);
      final item = batches.first.single;
      expect(item.videoPath, isNotNull);
      expect(File(item.imagePath).parent.path, File(item.videoPath!).parent.path);
      expect(File(item.imagePath).existsSync(), isTrue);
      expect(File(item.videoPath!).existsSync(), isTrue);
      expect(batches.last.single.imagePath, item.imagePath);
      expect(mediaLibraryCalls, isEmpty);
      expect(sharedArguments, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iOS requested invalid pair fails without silent still share', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final api = _MockLivePhotoApi();
    when(() => api.shareLivePhotos(any(), any(), any(), any(), any())).thenAnswer((_) async => false);
    repository = _TestAssetMediaRepository(nativeSync, storage, livePhotoApi: api);
    final context = await mountShareContext(tester);
    try {
      await tester.runAsync(() async {
        expect(
          await repository.shareAssets([
            TestUtils.createRemoteAsset(id: 'still').copyWith(livePhotoVideoId: 'motion'),
          ], context),
          0,
        );
      });
      expect(sharedArguments, isEmpty);
      expect(mediaLibraryCalls, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iOS image-only original mode intentionally does not download motion', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final context = await mountShareContext(tester);
    try {
      await tester.runAsync(() async {
        expect(
          await repository.shareAssets(
            [TestUtils.createRemoteAsset(id: 'still').copyWith(livePhotoVideoId: 'motion')],
            context,
            livePhotoMode: LivePhotoShareMode.imageOnly,
          ),
          1,
        );
      });
      expect(downloads.single.url, contains('/assets/still/original?'));
      expect(sharedArguments, hasLength(1));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'iOS merged Live Photo with deleted local ID resolves existing remote pair without importing duplicates',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final api = _MockLivePhotoApi();
      final remote = TestUtils.createRemoteAsset(id: 'server-still').copyWith(livePhotoVideoId: 'server-motion');
      when(() => storage.hasMediaLibraryAsset('deleted-local')).thenAnswer((_) async => false);
      when(() => storage.isAssetAvailableLocally('deleted-local')).thenAnswer((_) async => false);
      when(() => api.shareLivePhotos(any(), any(), any(), any(), any())).thenAnswer((_) async => true);
      repository = _TestAssetMediaRepository(
        nativeSync,
        storage,
        livePhotoApi: api,
        remoteAssetById: (_) async => remote,
      );
      final context = await mountShareContext(tester);
      try {
        await tester.runAsync(() async {
          expect(
            await repository.shareAssets([
              TestUtils.createLocalAsset(
                id: 'deleted-local',
                remoteId: 'server-still',
              ).copyWith(playbackStyle: AssetPlaybackStyle.livePhoto),
            ], context),
            1,
          );
        });
        expect(downloads, hasLength(2));
        expect(downloads.map((task) => task.url), contains(contains('/assets/server-motion/original?')));
        expect(mediaLibraryCalls, isEmpty);
        verifyNever(() => api.exportLivePhoto(any()));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('cancellation during native pair preparation prevents late chooser and retains resources', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final api = _MockLivePhotoApi();
    repository = _TestAssetMediaRepository(nativeSync, storage, livePhotoApi: api);
    final context = await mountShareContext(tester);
    try {
      await tester.runAsync(() async {
        final cancelled = Completer<void>();
        final started = Completer<List<LivePhotoShareItem>>();
        final completed = Completer<bool>();
        when(() => api.shareLivePhotos(any(), any(), any(), any(), any())).thenAnswer((invocation) {
          started.complete(invocation.positionalArguments.first as List<LivePhotoShareItem>);
          return completed.future;
        });
        when(api.cancelLivePhotoShare).thenAnswer((_) async {
          completed.complete(false);
        });
        final sharing = repository.shareAssets(
          [TestUtils.createRemoteAsset(id: 'still').copyWith(livePhotoVideoId: 'motion')],
          context,
          cancelCompleter: cancelled,
        );
        final item = (await started.future).single;
        cancelled.complete();
        expect(await sharing, 0);
        verify(api.cancelLivePhotoShare).called(1);
        expect(File(item.imagePath).existsSync(), isTrue);
        expect(File(item.videoPath!).existsSync(), isTrue);
      });
      expect(sharedArguments, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iOS local pair cancellation awaits native export drain without deleting original resources', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final api = _MockLivePhotoApi();
    when(() => storage.hasMediaLibraryAsset('local-live')).thenAnswer((_) async => true);
    when(() => api.cancelLivePhotoExport('local-live')).thenAnswer((_) async {});
    repository = _TestAssetMediaRepository(nativeSync, storage, livePhotoApi: api);
    final context = await mountShareContext(tester);
    try {
      await tester.runAsync(() async {
        final cancelled = Completer<void>();
        final export = Completer<LivePhotoResourcePair?>();
        final requestStarted = Completer<void>();
        when(() => api.exportLivePhoto('local-live')).thenAnswer((_) {
          requestStarted.complete();
          return export.future;
        });
        var completed = false;
        final sharing = repository
            .shareAssets(
              [TestUtils.createLocalAsset(id: 'local-live').copyWith(playbackStyle: AssetPlaybackStyle.livePhoto)],
              context,
              cancelCompleter: cancelled,
            )
            .then((count) {
              completed = true;
              return count;
            });
        await requestStarted.future;
        cancelled.complete();
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);
        verify(() => api.cancelLivePhotoExport('local-live')).called(1);
        export.complete(null);
        expect(await sharing, 0);
      });
      expect(repository.cleanups.expand((entities) => entities), isEmpty);
      expect(downloads, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('shares a local original without requesting a remote original or thumbnail', (tester) async {
    final file = localFile('IMG.jpg', [0xff, 0xd8, 1, 2, 3]);
    when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => file);
    final asset = TestUtils.createLocalAsset(id: 'local-1', remoteId: 'remote-1').copyWith(name: 'IMG.jpg');

    final result = await share(tester, [asset]);

    expect(result.count, 1);
    expect(result.names, ['IMG.jpg']);
    expect(result.mimeTypes, ['image/jpeg']);
    expect(downloads, isEmpty);
    expect(result.paths.single, isNot(file.path));
    expect(File(result.paths.single).readAsBytesSync(), file.readAsBytesSync());
    expect(file.existsSync(), isTrue);
    verify(() => storage.getFileForAsset('local-1')).called(1);
  });

  testWidgets('server-only photo uses the original endpoint and temporary file cache', (tester) async {
    final result = await share(tester, [TestUtils.createRemoteAsset(id: 'remote-photo').copyWith(name: 'photo.jpg')]);

    expect(result.count, 1);
    expect(result.mimeTypes, ['image/jpeg']);
    expect(downloads.single.url, 'https://example.com/api/assets/remote-photo/original?edited=false');
    expect(downloads.single.baseDirectory, BaseDirectory.temporary);
    expect(downloads.single.updates, Updates.statusAndProgress);
    expect(result.paths.single, startsWith(p.join(tempRoot.path, 'outgoing_share')));
    expect(File(result.paths.single).existsSync(), isTrue);
    expect(mediaLibraryCalls, isEmpty);
    verifyZeroInteractions(nativeSync);
  });

  testWidgets('server-only video shares the original rather than a transcode or preview', (tester) async {
    // Unknown payload still has an explicit original file extension.
    remoteBytes['remote-video'] = [1, 2, 3, 4];
    final asset = TestUtils.createRemoteAsset(id: 'remote-video').copyWith(name: 'clip.mp4', type: AssetType.video);

    final result = await share(tester, [asset], fileType: ShareAssetType.preview);

    expect(result.count, 1);
    expect(result.mimeTypes, ['video/mp4']);
    expect(result.names, ['clip.mp4']);
    expect(downloads.single.url, contains('/assets/remote-video/original?'));
    expect(downloads.single.url, isNot(contains('/playback')));
    expect(downloads.single.url, isNot(contains('/thumbnail')));
    expect(File(result.paths.single).readAsBytesSync(), [1, 2, 3, 4]);
    expect(mediaLibraryCalls, isEmpty);
  });

  testWidgets('multi-share keeps mixed local photo and remote photo/video in one ordered batch', (tester) async {
    final file = localFile('local.jpg', [0xff, 0xd8, 1]);
    when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => file);
    remoteBytes['video'] = [1, 2, 3];
    final assets = [
      TestUtils.createRemoteAsset(id: 'remote-1').copyWith(name: 'remote.jpg'),
      TestUtils.createLocalAsset(id: 'local-1').copyWith(name: 'local.jpg'),
      TestUtils.createRemoteAsset(id: 'video').copyWith(name: 'video.mp4', type: AssetType.video),
    ];
    final progress = <double>[];

    final result = await share(tester, assets, onProgress: progress.add);

    expect(result.count, 3);
    expect(result.names, ['remote.jpg', 'local.jpg', 'video.mp4']);
    expect(result.mimeTypes, ['image/jpeg', 'image/jpeg', 'video/mp4']);
    expect(sharedArguments, hasLength(1));
    expect(downloads, hasLength(2));
    expect(progress.first, 0);
    expect(progress.last, 1);
    expect(progress, contains(closeTo(1 / 6, 0.0001)));
    expect(progress.every((value) => value >= 0 && value <= 1), isTrue);
    expect(mediaLibraryCalls, isEmpty);
  });

  testWidgets('shares sanitized and fallback names and retains completed files for receivers', (tester) async {
    final assets = [
      TestUtils.createRemoteAsset(id: 'remote-1').copyWith(name: 'holiday/Photo 1 名字.jpg'),
      TestUtils.createRemoteAsset(id: 'remote-2').copyWith(name: ''),
      TestUtils.createRemoteAsset(id: 'remote-3').copyWith(name: r'\/'),
    ];

    final result = await share(tester, assets);

    expect(result.count, 3);
    expect(result.names, ['holiday_Photo 1 名字.jpg', 'remote-2', 'remote-3']);
    expect(result.paths.every((path) => File(path).existsSync()), isTrue);
    expect(result.mimeTypes, everyElement('image/jpeg'));
    expect(repository.cleanups.expand((files) => files), isEmpty);
  });

  testWidgets('keeps the first copy and uses the first free ordinal for the next', (tester) async {
    final assets = [
      TestUtils.createRemoteAsset(id: 'remote-1').copyWith(name: 'IMG.jpg'),
      TestUtils.createRemoteAsset(id: 'remote-2').copyWith(name: 'IMG (1).jpg'),
      TestUtils.createRemoteAsset(id: 'remote-3').copyWith(name: 'IMG.jpg'),
    ];

    final result = await share(tester, assets);

    expect(result.count, 3);
    expect(result.names, ['IMG.jpg', 'IMG (1).jpg', 'IMG (2).jpg']);
  });

  testWidgets('keeps mixed local and remote paths distinct without changing originals', (tester) async {
    final file = localFile('IMG.jpg', [0xff, 0xd8, 1]);
    when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => file);
    final assets = [
      TestUtils.createRemoteAsset(id: 'remote-1').copyWith(name: 'IMG.jpg'),
      TestUtils.createLocalAsset(id: 'local-1').copyWith(name: 'IMG.jpg'),
    ];

    final result = await share(tester, assets);

    expect(result.count, 2);
    expect(result.names, ['IMG.jpg', 'IMG (1).jpg']);
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync(), [0xff, 0xd8, 1]);
  });

  testWidgets('does not count failed downloads when adding ordinals', (tester) async {
    failedRemoteIds.add('remote-1');
    final assets = [
      TestUtils.createRemoteAsset(id: 'remote-1').copyWith(name: 'IMG.jpg'),
      TestUtils.createRemoteAsset(id: 'remote-2').copyWith(name: 'IMG.jpg'),
    ];

    final result = await share(tester, assets);

    expect(result.count, 1);
    expect(result.names, ['IMG.jpg']);
    expect(repository.cleanups.expand((files) => files), hasLength(1));
  });

  testWidgets('network failure returns zero, removes partial cache, and never opens share sheet', (tester) async {
    failedRemoteIds.add('offline');

    final result = await share(tester, [TestUtils.createRemoteAsset(id: 'offline')]);

    expect(result.count, 0);
    expect(sharedArguments, isEmpty);
    final partialFile = File(await downloads.single.filePath());
    expect(partialFile.existsSync(), isFalse);
    expect(mediaLibraryCalls, isEmpty);
  });

  testWidgets('a successful-status empty original is rejected and its partial cache is removed', (tester) async {
    remoteBytes['empty-original'] = [];

    final result = await share(tester, [TestUtils.createRemoteAsset(id: 'empty-original')]);

    expect(result.count, 0);
    expect(sharedArguments, isEmpty);
    final downloadedFile = File(await downloads.single.filePath());
    expect(downloadedFile.existsSync(), isFalse);
    expect(File(p.join(downloadedFile.parent.path, '.complete')).existsSync(), isFalse);
    expect(mediaLibraryCalls, isEmpty);
  });

  testWidgets('stale local reference falls back to server original', (tester) async {
    when(() => storage.getFileForAsset('deleted-local')).thenAnswer((_) async => null);
    final asset = TestUtils.createRemoteAsset(id: 'remote-1').copyWith(localId: 'deleted-local');

    final result = await share(tester, [asset]);

    expect(result.count, 1);
    expect(downloads.single.url, contains('/assets/remote-1/original?'));
    verify(() => storage.getFileForAsset('deleted-local')).called(1);
  });

  testWidgets('reuses a completed original cache across shares without another download', (tester) async {
    final asset = TestUtils.createRemoteAsset(id: 'remote-1');
    final first = await share(tester, [asset]);
    final second = await share(tester, [asset]);

    expect(first.count, 1);
    expect(second.count, 1);
    expect(second.paths, first.paths);
    expect(downloads, hasLength(1));
    expect(File(first.paths.single).existsSync(), isTrue);
    expect(mediaLibraryCalls, isEmpty);
  });

  testWidgets('changed asset timestamp invalidates the original share cache', (tester) async {
    final asset = TestUtils.createRemoteAsset(id: 'remote-1');
    final first = await share(tester, [asset]);
    final second = await share(tester, [asset.copyWith(updatedAt: asset.updatedAt.add(const Duration(seconds: 1)))]);

    expect(second.paths, isNot(first.paths));
    expect(downloads, hasLength(2));
    expect(File(first.paths.single).existsSync(), isTrue);
  });

  testWidgets('corrupt cached MIME metadata reuses the original and infers its MIME without another download', (
    tester,
  ) async {
    final asset = TestUtils.createRemoteAsset(id: 'remote-1').copyWith(name: 'photo.jpg');
    final first = await share(tester, [asset]);
    final original = File(first.paths.single);
    File(p.join(original.parent.path, '.complete')).writeAsStringSync('{"mimeType":');

    final second = await share(tester, [asset]);

    expect(second.count, 1);
    expect(second.paths, first.paths);
    expect(second.mimeTypes, ['image/jpeg']);
    expect(downloads, hasLength(1));
    expect(original.existsSync(), isTrue);
  });

  testWidgets('concurrent shares of the same original download once and retain both receivers files', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final context = await mountShareContext(tester);
      final asset = TestUtils.createRemoteAsset(id: 'concurrent-original');
      stalledRemoteIds.add(asset.id);
      final secondRepository = _TestAssetMediaRepository(nativeSync, storage);

      final counts = await tester.runAsync(() async {
        final started = Completer<DownloadTask>();
        onTaskStarted = started.complete;
        final first = repository.shareAssets([asset], context);
        final task = await started.future;
        final second = secondRepository.shareAssets([asset], context);
        await Future<void>.delayed(Duration.zero);
        expect(downloads, hasLength(1));

        FileDownloader().downloaderForTesting.processStatusUpdate(TaskStatusUpdate(task, TaskStatus.complete));
        return Future.wait([first, second]);
      });

      expect(counts, [1, 1]);
      expect(downloads, hasLength(1));
      expect(sharedArguments, hasLength(2));
      expect(sharedArguments[0]['paths'], sharedArguments[1]['paths']);
      final paths = (sharedArguments.first['paths']! as List).cast<String>();
      expect(paths.every((path) => File(path).existsSync()), isTrue);
      expect(mediaLibraryCalls, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('immediate retry waits for delayed native cancellation and old partial cleanup', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final context = await mountShareContext(tester);
      final asset = TestUtils.createRemoteAsset(id: 'cancel-then-retry');
      stalledRemoteIds.add(asset.id);

      final counts = await tester.runAsync(() async {
        final started = Completer<DownloadTask>();
        final cancellationEntered = Completer<void>();
        final releaseCancellation = Completer<void>();
        final cancellation = Completer<void>();
        onTaskStarted = (task) {
          if (!started.isCompleted) {
            started.complete(task);
          }
        };
        // The task has already emitted cancelled, but the native worker still
        // holds its cancellation request. A retry must wait for its final ack.
        afterCancellationStatus = () async {
          if (!cancellationEntered.isCompleted) {
            cancellationEntered.complete();
          }
          await releaseCancellation.future;
        };
        final first = repository.shareAssets([asset], context, cancelCompleter: cancellation);
        await started.future;
        cancellation.complete();
        await cancellationEntered.future;

        stalledRemoteIds.clear();
        final retry = repository.shareAssets([asset], context);
        await Future<void>.delayed(Duration.zero);
        expect(downloads, hasLength(1));
        expect(sharedArguments, isEmpty);
        releaseCancellation.complete();
        return Future.wait([first, retry]);
      });

      expect(counts, [0, 1]);
      expect(downloads, hasLength(2));
      expect(cancelledTaskIds, [downloads.first.taskId]);
      expect(sharedArguments, hasLength(1));
      final paths = (sharedArguments.single['paths']! as List).cast<String>();
      expect(paths.single, await downloads.last.filePath());
      expect(File(paths.single).existsSync(), isTrue);
      expect(File(p.join(File(paths.single).parent.path, '.complete')).existsSync(), isTrue);
      expect(mediaLibraryCalls, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a later share retains previous receivers files and purges only expired cache', (tester) async {
    final first = await share(tester, [TestUtils.createRemoteAsset(id: 'remote-1')]);
    final originalFile = File(first.paths.single);
    final expired = Directory(p.join(tempRoot.path, 'outgoing_share', 'expired'))..createSync();
    final expiredFile = File(p.join(expired.path, 'old.jpg'))..writeAsBytesSync([1, 2, 3]);
    final expiredMarker = File(p.join(expired.path, '.complete'))..writeAsStringSync('complete');
    expiredMarker.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 8)));

    await share(tester, [TestUtils.createRemoteAsset(id: 'remote-2')]);

    expect(originalFile.existsSync(), isTrue);
    expect(expiredFile.existsSync(), isFalse);
    expect(expired.existsSync(), isFalse);
  });

  testWidgets('cancels a stalled download even without a progress callback', (tester) async {
    stalledRemoteIds.add('stalled-video');
    final cancellation = (await tester.runAsync(() async => Completer<void>()))!;
    final asset = TestUtils.createRemoteAsset(id: 'stalled-video').copyWith(name: 'video.mp4', type: AssetType.video);
    onTaskStarted = (_) => cancellation.complete();
    final result = await share(tester, [asset], cancelCompleter: cancellation);
    final task = downloads.single;

    expect(result.count, 0);
    expect(cancelledTaskIds, contains(task.taskId));
    expect(sharedArguments, isEmpty);
    expect(File(await task.filePath()).existsSync(), isFalse);
    expect(mediaLibraryCalls, isEmpty);
  });

  testWidgets('iOS cancellation during local retrieval never deletes a library original', (tester) async {
    final cancellation = Completer<void>();
    final file = localFile('IMG.jpg', [0xff, 0xd8, 1]);
    when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async {
      cancellation.complete();
      return file;
    });
    final asset = TestUtils.createLocalAsset(id: 'local-1').copyWith(name: 'IMG.jpg');

    final result = await share(tester, [asset], cancelCompleter: cancellation, platform: TargetPlatform.iOS);

    expect(result.count, 0);
    expect(sharedArguments, isEmpty);
    expect(file.existsSync(), isTrue);
    expect(repository.cleanups.expand((files) => files).map((entity) => entity.path), isNot(contains(file.path)));
  });

  testWidgets('adds an ordinal when preview and video original names match', (tester) async {
    final assets = [
      TestUtils.createRemoteAsset(id: 'remote-1').copyWith(name: 'IMG.jpg'),
      TestUtils.createRemoteAsset(id: 'remote-2').copyWith(name: 'IMG-preview.jpg', type: AssetType.video),
    ];

    final result = await share(tester, assets, fileType: ShareAssetType.preview);

    expect(result.count, 2);
    expect(result.names, ['IMG-preview.jpg', 'IMG-preview (1).jpg']);
    expect(downloads.first.url, contains('/thumbnail?size=preview'));
    expect(downloads.last.url, contains('/original?'));
  });

  testWidgets('MIME is explicit for JPEG MP4 HEIC and unnamed original bytes', (tester) async {
    remoteBytes['mp4'] = [1, 2, 3];
    remoteBytes['heic'] = [1, 2, 3];
    final assets = [
      TestUtils.createRemoteAsset(id: 'jpg').copyWith(name: 'photo.jpg'),
      TestUtils.createRemoteAsset(id: 'mp4').copyWith(name: 'video.mp4', type: AssetType.video),
      TestUtils.createRemoteAsset(id: 'heic').copyWith(name: 'photo.heic'),
      TestUtils.createRemoteAsset(id: 'unnamed').copyWith(name: ''),
    ];

    final result = await share(tester, assets);

    expect(result.mimeTypes, ['image/jpeg', 'video/mp4', 'image/heic', 'image/jpeg']);
    expect(sharedArguments.single['displayNames'], ['photo.jpg', 'video.mp4', 'photo.heic', 'unnamed']);
  });

  testWidgets('an iOS original absent from device uses Gallery without an untracked iCloud export', (tester) async {
    when(() => storage.isAssetAvailableLocally('cloud-local-id')).thenAnswer((_) async => false);
    final asset = TestUtils.createRemoteAsset(id: 'remote-1').copyWith(localId: 'cloud-local-id');

    final result = await share(tester, [asset], platform: TargetPlatform.iOS);

    expect(result.count, 1);
    expect(downloads.single.url, contains('/assets/remote-1/original?'));
    verify(() => storage.isAssetAvailableLocally('cloud-local-id')).called(1);
    verifyNever(() => storage.getFileForAsset(any()));
    expect(File(result.paths.single).existsSync(), isTrue);
    expect(mediaLibraryCalls, isEmpty);
  });

  testWidgets('unknown original filename retains server MIME metadata on repeated shares', (tester) async {
    remoteBytes['opaque-video'] = [1, 2, 3, 4];
    responseMimeTypes['opaque-video'] = 'video/mp4';
    final asset = TestUtils.createRemoteAsset(id: 'opaque-video').copyWith(name: '', type: AssetType.video);

    final first = await share(tester, [asset]);
    final second = await share(tester, [asset]);

    expect(first.mimeTypes, ['video/mp4']);
    expect(second.mimeTypes, ['video/mp4']);
    expect(second.paths, first.paths);
    expect(downloads, hasLength(1));
  });

  testWidgets('cancellation of a later share preserves previously completed receiver files', (tester) async {
    final photo = TestUtils.createRemoteAsset(id: 'remote-photo');
    final first = await share(tester, [photo]);
    stalledRemoteIds.add('stalled-video');
    final cancellation = (await tester.runAsync(() async => Completer<void>()))!;
    onTaskStarted = (_) => cancellation.complete();
    final video = TestUtils.createRemoteAsset(id: 'stalled-video').copyWith(name: 'video.mp4', type: AssetType.video);

    final cancelled = await share(tester, [photo, video], cancelCompleter: cancellation);

    expect(cancelled.count, 0);
    expect(sharedArguments, hasLength(1));
    expect(downloads, hasLength(2));
    expect(File(first.paths.single).existsSync(), isTrue);
    expect(File(await downloads.last.filePath()).existsSync(), isFalse);
  });

  testWidgets('iOS uses existing system share path and retains its staged local original', (tester) async {
    final file = localFile('photo.heic', [1, 2, 3]);
    when(() => storage.getFileForAsset('local-ios')).thenAnswer((_) async => file);
    final asset = TestUtils.createLocalAsset(id: 'local-ios').copyWith(name: 'photo.heic');

    final result = await share(tester, [asset], platform: TargetPlatform.iOS);

    expect(result.count, 1);
    expect(result.mimeTypes, ['image/heic']);
    expect(downloads, isEmpty);
    expect(file.existsSync(), isTrue);
    expect(File(result.paths.single).existsSync(), isTrue);
    expect(mediaLibraryCalls, isEmpty);
  });

  testWidgets('sharing a Live or Motion Photo requests only its still original and preserves pairing', (tester) async {
    final asset = TestUtils.createRemoteAsset(
      id: 'live-still',
    ).copyWith(name: 'live.jpg', livePhotoVideoId: 'paired-motion', stackId: 'existing-stack');

    final result = await share(tester, [asset]);

    expect(result.count, 1);
    expect(downloads.single.url, contains('/assets/live-still/original?'));
    expect(downloads.every((task) => !task.url.contains('paired-motion')), isTrue);
    expect(asset.livePhotoVideoId, 'paired-motion');
    expect(asset.stackId, 'existing-stack');
    expect(asset.playbackStyle, AssetPlaybackStyle.livePhoto);
    expect(mediaLibraryCalls, isEmpty);
  });
}
