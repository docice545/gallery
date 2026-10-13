import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/data_controller.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/domain/services/hash.service.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/sync_stream.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/utils/option.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/asset.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../medium/repository_context.dart';
import '../../mocks/asset_entity.mock.dart';
import '../../repository.mocks.dart';
import '../../service.mocks.dart';

class _DataController extends Mock implements DataController {}

class _LocalSync extends Mock implements LocalSyncService {}

class _RemoteSync extends Mock implements SyncStreamService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MediumRepositoryContext context;
  late _LocalSync localSync;
  late _RemoteSync remoteSync;
  late MockNativeSyncApi native;
  late MockUploadRepository uploads;
  late BackgroundUploadService uploader;
  late BackgroundWorkerBgService worker;
  late Completer<void> cancellation;
  late List<String> events;
  late List<UploadTask> enqueued;
  late int closeCount;

  setUpAll(() async {
    registerFallbackValue(<UploadTask>[]);
    registerFallbackValue(<String>[]);
    registerFallbackValue(LocalAssetStub.image1);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => '/tmp',
    );
    context = MediumRepositoryContext();
    await context.newUser(id: 'owner');
    await context.newAuthUser(id: 'owner');
    await context.newLocalAlbum(id: 'camera', backupSelection: BackupSelection.selected);
    await StoreService.init(storeRepository: StoreRepository(context.db), listenUpdates: false);
    await SettingsRepository.ensureInitialized(context.db);
    await Store.put(StoreKey.serverEndpoint, 'https://gallery.invalid/api');
    await Store.put(StoreKey.deviceId, 'synthetic-device');
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await context.db.delete(context.db.localAlbumAssetEntity).go();
    await context.db.delete(context.db.localAssetEntity).go();
    localSync = _LocalSync();
    remoteSync = _RemoteSync();
    native = MockNativeSyncApi();
    uploads = MockUploadRepository();
    cancellation = Completer<void>();
    events = [];
    enqueued = [];
    closeCount = 0;
    when(() => localSync.sync()).thenAnswer((_) async => events.add('scan'));
    when(() => localSync.cancelNativeWork()).thenAnswer((_) async => events.add('cancel-scan'));
    when(() => remoteSync.sync()).thenAnswer((_) async {
      events.add('remote');
      return true;
    });
    when(() => native.cancelHashing()).thenAnswer((_) async => events.add('cancel-hash'));
    final storage = MockStorageRepository();
    final media = MockAssetMediaRepository();
    final entity = MockAssetEntity();
    when(() => entity.isLivePhoto).thenReturn(false);
    when(() => storage.clearCache()).thenAnswer((_) async {});
    when(() => storage.getAssetEntityForAsset(any())).thenAnswer((_) async => entity);
    when(() => storage.getFileForAsset('new-photo')).thenAnswer((_) async => File('/tmp/synthetic.jpg'));
    when(() => media.getOriginalFilename('new-photo')).thenAnswer((_) async => 'synthetic.jpg');
    when(() => uploads.enqueueBackgroundAll(any())).thenAnswer((invocation) async {
      final tasks = invocation.positionalArguments[0] as List<UploadTask>;
      enqueued.addAll(tasks);
      events.add('enqueue');
      return List.filled(tasks.length, true);
    });
    uploader = BackgroundUploadService(
      uploads,
      storage,
      LocalAssetRepository(context.db),
      BackupRepository(context.db),
      media,
    );
    worker = BackgroundWorkerBgService.forTesting(
      dataController: _DataController(),
      localSyncService: localSync,
      remoteSyncService: remoteSync,
      hashService: HashService(
        localAlbumRepository: LocalAlbumRepository(context.db),
        localAssetRepository: LocalAssetRepository(context.db),
        nativeSyncApi: native,
        trashedLocalAssetRepository: TrashedLocalAssetRepository(context.db),
        cancellation: cancellation,
        rethrowErrors: true,
      ),
      handleBackup: () async {
        expect(closeCount, 0);
        events.add('backup');
        await uploader.uploadBackupCandidates('owner');
      },
      closeResources: () async {
        await uploader.stopAndDrain();
        events.add('close');
        closeCount++;
      },
      cancellation: cancellation,
    );
  });

  tearDown(() async {
    await worker.cancel();
    debugDefaultTargetPlatformOverride = null;
  });

  tearDownAll(() async {
    await SettingsRepository.reset();
    await StoreService.I.dispose();
    await context.dispose();
  });

  Future<void> seedUnhashedPhoto() async {
    await context.newLocalAsset(id: 'new-photo', checksumOption: const Option.none());
    await context.newLocalAlbumAsset(albumId: 'camera', assetId: 'new-photo');
  }

  test('one iOS wake uploads a photo discovered by delayed scan and delayed native hashing', () async {
    final scanStarted = Completer<void>();
    final releaseScan = Completer<void>();
    final hashingStarted = Completer<void>();
    final releaseHash = Completer<void>();
    when(() => localSync.sync()).thenAnswer((_) async {
      scanStarted.complete();
      await releaseScan.future;
      await seedUnhashedPhoto();
      events.add('scan');
    });
    when(() => native.hashAssets(['new-photo'], allowNetworkAccess: true)).thenAnswer((_) async {
      hashingStarted.complete();
      await releaseHash.future;
      events.add('hash');
      return [HashResult(assetId: 'new-photo', hash: 'verified-bytes')];
    });
    final running = worker.onIosUpload(false, 60);
    await scanStarted.future;
    expect(enqueued, isEmpty);
    releaseScan.complete();
    // The broken parallel implementation returns without ever hashing the
    // newly discovered photo. Race the hash signal against completion so the
    // regression fails deterministically instead of hanging.
    final startedHash = await Future.any([hashingStarted.future.then((_) => true), running.then((_) => false)]);
    expect(startedHash, isTrue, reason: 'The same wake must hash assets discovered during its local scan');
    expect(enqueued, isEmpty);
    releaseHash.complete();
    expect(await running, isTrue);
    expect(enqueued.map((task) => task.taskId), ['new-photo']);
    expect(events.where((event) => ['scan', 'remote', 'hash', 'backup', 'enqueue', 'close'].contains(event)), [
      'scan',
      'remote',
      'hash',
      'backup',
      'enqueue',
      'close',
    ]);
    expect(closeCount, 1);
  });

  test('failed remote synchronization does not query or enqueue backup candidates', () async {
    when(() => remoteSync.sync()).thenAnswer((_) async => false);
    expect(await worker.onIosUpload(true, 60), isFalse);
    expect(events, isNot(contains('backup')));
    expect(enqueued, isEmpty);
    verifyNever(() => native.hashAssets(any(), allowNetworkAccess: any(named: 'allowNetworkAccess')));
    expect(closeCount, 1);
  });

  test('failed native hash does not enqueue unhashed photos or report success', () async {
    await seedUnhashedPhoto();
    when(
      () => native.hashAssets(['new-photo'], allowNetworkAccess: true),
    ).thenAnswer((_) async => [HashResult(assetId: 'new-photo', error: 'resource unavailable')]);
    expect(await worker.onIosUpload(false, 60), isFalse);
    expect(events, isNot(contains('backup')));
    expect(enqueued, isEmpty);
    expect(closeCount, 1);
  });

  test('cancellation during scan drains it before closing without starting later phases', () async {
    final started = Completer<void>();
    final releaseScan = Completer<void>();
    when(() => localSync.sync()).thenAnswer((_) async {
      started.complete();
      await releaseScan.future;
      expect(closeCount, 0);
      events.add('scan-drained');
    });
    final running = worker.onIosUpload(false, 60);
    await started.future;
    final stopped = worker.cancel();
    expect(cancellation.isCompleted, isTrue);
    expect(closeCount, 0);
    releaseScan.complete();
    await stopped;
    expect(await running, isFalse);
    verifyNever(() => remoteSync.sync());
    expect(events, isNot(contains('backup')));
    expect(events.indexOf('scan-drained'), lessThan(events.indexOf('close')));
    expect(closeCount, 1);
  });

  test('cancellation during native hashing drains its reply without enqueueing or closing the DB early', () async {
    await seedUnhashedPhoto();
    final started = Completer<void>();
    final releaseHash = Completer<void>();
    when(() => native.hashAssets(['new-photo'], allowNetworkAccess: true)).thenAnswer((_) async {
      started.complete();
      await releaseHash.future;
      expect(closeCount, 0);
      events.add('hash-drained');
      return [HashResult(assetId: 'new-photo', hash: 'verified-bytes')];
    });
    final running = worker.onIosUpload(false, 60);
    await started.future;
    final stopped = worker.cancel();
    expect(cancellation.isCompleted, isTrue);
    expect(closeCount, 0);
    releaseHash.complete();
    await stopped;
    expect(await running, isFalse);
    expect(events, isNot(contains('backup')));
    expect(enqueued, isEmpty);
    expect(events.indexOf('hash-drained'), lessThan(events.indexOf('close')));
    expect((await LocalAssetRepository(context.db).getById('new-photo'))?.checksum, isNull);
    expect(closeCount, 1);
  });

  test('iOS time budget cancels and drains a delayed scan without detached DB access', () async {
    final started = Completer<void>();
    final releaseScan = Completer<void>();
    when(() => localSync.sync()).thenAnswer((_) async {
      started.complete();
      await releaseScan.future;
      expect(closeCount, 0);
      events.add('scan-drained');
    });
    final running = worker.onIosUpload(true, 2);
    await started.future;
    await cancellation.future;
    expect(cancellation.isCompleted, isTrue);
    expect(closeCount, 0);
    releaseScan.complete();
    expect(await running, isFalse);
    verifyNever(() => remoteSync.sync());
    expect(events, isNot(contains('backup')));
    expect(closeCount, 1);
  });
}
