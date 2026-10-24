import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/pending_local_trash.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/asset.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../repository.mocks.dart';
import '../../service.mocks.dart';

void main() {
  late LocalSyncService sut;
  late LocalAlbumRepository mockLocalAlbumRepository;
  late TrashedLocalAssetRepository mockTrashedLocalAssetRepository;
  late AssetMediaRepository mockAssetMediaRepository;
  late MockPermissionRepository mockPermissionRepository;
  late MockNativeSyncApi mockNativeSyncApi;
  late Drift db;
  var manageMediaPermissionGranted = false;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    registerFallbackValue(
      PendingLocalTrash(
        key: 'fallback',
        rawValue: 'fallback',
        asset: LocalAssetStub.image1,
        albumIds: const ['camera'],
        remoteReasons: const {'remote': false},
        attempts: 1,
        nextAttemptAt: DateTime.utc(2026),
      ),
    );

    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
  });

  tearDownAll(() async {
    debugDefaultTargetPlatformOverride = null;
    await Store.clear();
    await db.close();
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    manageMediaPermissionGranted = false;
    mockLocalAlbumRepository = MockLocalAlbumRepository();
    mockTrashedLocalAssetRepository = MockTrashedLocalAssetRepository();
    mockAssetMediaRepository = MockAssetMediaRepository();
    mockPermissionRepository = MockPermissionRepository();
    mockNativeSyncApi = MockNativeSyncApi();

    when(() => mockNativeSyncApi.shouldFullSync()).thenAnswer((_) async => false);
    when(() => mockNativeSyncApi.getMediaChanges()).thenAnswer(
      (_) async => SyncDelta(hasChanges: false, updates: const [], deletes: const [], assetAlbums: const {}),
    );
    when(() => mockNativeSyncApi.getTrashedAssets()).thenAnswer((_) async => {});
    when(() => mockTrashedLocalAssetRepository.processTrashSnapshot(any())).thenAnswer((_) async {});
    when(() => mockTrashedLocalAssetRepository.updateManageMediaPermission(any())).thenAnswer((_) async => false);
    when(() => mockTrashedLocalAssetRepository.clearPermissionHashFailures()).thenAnswer((_) async {});
    when(() => mockTrashedLocalAssetRepository.getToRestore()).thenAnswer((_) async => []);
    when(() => mockTrashedLocalAssetRepository.getToTrash()).thenAnswer((_) async => {});
    when(() => mockTrashedLocalAssetRepository.applyRestoredAssets(any())).thenAnswer((_) async {});
    when(() => mockTrashedLocalAssetRepository.trashLocalAsset(any())).thenAnswer((_) async {});
    when(() => mockTrashedLocalAssetRepository.enqueueTrash(any())).thenAnswer((_) async {});
    when(
      () => mockTrashedLocalAssetRepository.claimPendingTrash(now: any(named: 'now'), limit: 32),
    ).thenAnswer((_) async => []);
    when(
      () => mockTrashedLocalAssetRepository.retryPermissionBlockedTrash(now: any(named: 'now')),
    ).thenAnswer((_) async {});

    when(() => mockAssetMediaRepository.deleteAll(any())).thenAnswer((invocation) async {
      final ids = invocation.positionalArguments.first as List<String>;
      return ids;
    });

    when(() => mockTrashedLocalAssetRepository.retryPermissionBlockedTrash()).thenAnswer((_) async {});

    sut = LocalSyncService(
      localAlbumRepository: mockLocalAlbumRepository,
      trashedLocalAssetRepository: mockTrashedLocalAssetRepository,
      assetMediaRepository: mockAssetMediaRepository,
      permissionRepository: mockPermissionRepository,
      nativeSyncApi: mockNativeSyncApi,
    );

    await Store.put(StoreKey.manageLocalMediaAndroid, false);
    when(
      () => mockPermissionRepository.hasManageMediaPermission(),
    ).thenAnswer((_) async => manageMediaPermissionGranted);
  });

  group('LocalSyncService - syncTrashedAssets gating', () {
    test('invokes syncTrashedAssets when Android flag enabled and permission granted', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      await Future<void>.delayed(Duration.zero);
      manageMediaPermissionGranted = true;
      expect(Store.get(StoreKey.manageLocalMediaAndroid, false), isTrue);

      await sut.sync();

      verify(() => mockPermissionRepository.hasManageMediaPermission()).called(1);
      verify(() => mockNativeSyncApi.getTrashedAssets()).called(1);
      verify(() => mockTrashedLocalAssetRepository.processTrashSnapshot(any())).called(1);
    });

    test('clears permission hash suppression only when MANAGE_MEDIA is restored', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      manageMediaPermissionGranted = true;
      when(() => mockTrashedLocalAssetRepository.updateManageMediaPermission(true)).thenAnswer((_) async => true);

      await sut.sync();

      verify(() => mockTrashedLocalAssetRepository.clearPermissionHashFailures()).called(1);
    });

    test('skips syncTrashedAssets when store flag disabled', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, false);
      manageMediaPermissionGranted = true;

      await sut.sync();

      verifyNever(() => mockNativeSyncApi.getTrashedAssets());
    });

    test('skips syncTrashedAssets when MANAGE_MEDIA permission absent', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => false);

      await sut.sync();

      verifyNever(() => mockNativeSyncApi.getTrashedAssets());
    });

    test('skips syncTrashedAssets on non-Android platforms', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      manageMediaPermissionGranted = true;

      await sut.sync();

      verifyNever(() => mockNativeSyncApi.getTrashedAssets());
    });
  });

  group('LocalSyncService - syncTrashedAssets behavior', () {
    test('processes trashed snapshot without silently restoring intentionally deleted device copies', () async {
      final platformAsset = PlatformAsset(
        id: 'remote-id',
        name: 'remote.jpg',
        type: AssetType.image.index,
        durationMs: 0,
        orientation: 0,
        isFavorite: false,
        playbackStyle: PlatformAssetPlaybackStyle.image,
      );

      final assetsToRestore = [LocalAssetStub.image1];
      when(() => mockTrashedLocalAssetRepository.getToRestore()).thenAnswer((_) async => assetsToRestore);
      final restoredIds = ['image1'];
      when(() => mockAssetMediaRepository.restoreAssetsFromTrash(any())).thenAnswer((invocation) async {
        final Iterable<LocalAsset> requested = invocation.positionalArguments.first as Iterable<LocalAsset>;
        expect(requested, orderedEquals(assetsToRestore));
        return restoredIds;
      });

      final localAssetToTrash = LocalAssetStub.image2.copyWith(id: 'local-trash', checksum: 'checksum-trash');
      when(() => mockTrashedLocalAssetRepository.getToTrash()).thenAnswer(
        (_) async => {
          'album-a': [localAssetToTrash],
        },
      );

      await sut.processTrashedAssets({
        'album-a': [platformAsset],
      });

      final trashedSnapshot =
          verify(() => mockTrashedLocalAssetRepository.processTrashSnapshot(captureAny())).captured.single
              as Iterable<TrashedAsset>;
      expect(trashedSnapshot.length, 1);
      final trashedEntry = trashedSnapshot.single;
      expect(trashedEntry.albumId, 'album-a');
      expect(trashedEntry.asset.id, platformAsset.id);
      expect(trashedEntry.asset.name, platformAsset.name);
      verify(() => mockTrashedLocalAssetRepository.getToTrash()).called(1);

      verifyNever(() => mockAssetMediaRepository.restoreAssetsFromTrash(any()));
      verifyNever(() => mockTrashedLocalAssetRepository.applyRestoredAssets(any()));

      final queued =
          verify(() => mockTrashedLocalAssetRepository.enqueueTrash(captureAny())).captured.single
              as Map<String, List<LocalAsset>>;
      expect(queued, {
        'album-a': [localAssetToTrash],
      });
      verifyNever(() => mockAssetMediaRepository.deleteAll(any()));
      verifyNever(() => mockTrashedLocalAssetRepository.trashLocalAsset(any()));
    });

    test('device discovery and checkpoint finish independently of an unresolved trash operation', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      manageMediaPermissionGranted = true;
      final pending = PendingLocalTrash(
        key: 'pending',
        rawValue: 'claimed',
        asset: LocalAssetStub.image1,
        albumIds: const ['album-a'],
        remoteReasons: const {'remote': false},
        attempts: 1,
        nextAttemptAt: DateTime.utc(2026),
      );
      when(
        () => mockTrashedLocalAssetRepository.claimPendingTrash(now: any(named: 'now'), limit: 32),
      ).thenAnswer((_) async => [pending]);
      final nativeResult = Completer<void>();
      when(() => mockAssetMediaRepository.trashForSync(any())).thenAnswer((_) async {
        await nativeResult.future;
        throw PlatformException(code: 'deleteWithIds failed');
      });
      when(
        () => mockTrashedLocalAssetRepository.failPendingTrash(pending, any(), any(), now: any(named: 'now')),
      ).thenAnswer((_) async {});
      when(
        () => mockNativeSyncApi.getMediaChanges(),
      ).thenAnswer((_) async => SyncDelta(hasChanges: true, updates: [], deletes: [], assetAlbums: {}));
      when(() => mockNativeSyncApi.getAlbums()).thenAnswer((_) async => []);
      when(() => mockLocalAlbumRepository.updateAll(any())).thenAnswer((_) async {});
      when(
        () => mockLocalAlbumRepository.processDelta(
          updates: any(named: 'updates'),
          deletes: any(named: 'deletes'),
          assetAlbums: any(named: 'assetAlbums'),
        ),
      ).thenAnswer((_) async {});
      when(() => mockLocalAlbumRepository.getAll()).thenAnswer((_) async => []);
      when(() => mockNativeSyncApi.checkpointSync()).thenAnswer((_) async {});

      final trashTask = sut.processPendingTrash();
      await Future<void>.delayed(Duration.zero);
      await sut.sync().timeout(const Duration(seconds: 2));
      expect(nativeResult.isCompleted, isFalse);
      verifyInOrder([
        () => mockNativeSyncApi.getMediaChanges(),
        () => mockLocalAlbumRepository.processDelta(
          updates: any(named: 'updates'),
          deletes: any(named: 'deletes'),
          assetAlbums: any(named: 'assetAlbums'),
        ),
        () => mockNativeSyncApi.checkpointSync(),
      ]);
      nativeResult.complete();
      await trashTask;
      verify(
        () => mockTrashedLocalAssetRepository.failPendingTrash(
          pending,
          'deleteWithIds failed',
          any(),
          now: any(named: 'now'),
        ),
      ).called(1);
      verifyNever(() => mockTrashedLocalAssetRepository.completePendingTrash(any()));
      verifyNever(() => mockAssetMediaRepository.deleteAll(any(), trash: false));
    });

    test('does not attempt restore when repository has no assets to restore', () async {
      when(() => mockTrashedLocalAssetRepository.getToRestore()).thenAnswer((_) async => []);

      await sut.processTrashedAssets({});

      final trashedSnapshot =
          verify(() => mockTrashedLocalAssetRepository.processTrashSnapshot(captureAny())).captured.single
              as Iterable<TrashedAsset>;
      expect(trashedSnapshot, isEmpty);
      verifyNever(() => mockAssetMediaRepository.restoreAssetsFromTrash(any()));
      verifyNever(() => mockTrashedLocalAssetRepository.applyRestoredAssets(any()));
    });

    test('does not move local assets when repository finds nothing to trash', () async {
      when(() => mockTrashedLocalAssetRepository.getToTrash()).thenAnswer((_) async => {});

      await sut.processTrashedAssets({});

      verifyNever(() => mockAssetMediaRepository.deleteAll(any()));
      verifyNever(() => mockTrashedLocalAssetRepository.trashLocalAsset(any()));
    });
  });

  group('LocalSyncService - PlatformAsset conversion', () {
    test('toLocalAsset uses correct updatedAt timestamp', () {
      final platformAsset = PlatformAsset(
        id: 'test-id',
        name: 'test.jpg',
        type: AssetType.image.index,
        durationMs: 0,
        orientation: 0,
        isFavorite: false,
        createdAt: 1700000000,
        updatedAt: 1732000000,
        playbackStyle: PlatformAssetPlaybackStyle.image,
      );

      final localAsset = platformAsset.toLocalAsset();

      expect(localAsset.createdAt.millisecondsSinceEpoch ~/ 1000, 1700000000);
      expect(localAsset.updatedAt.millisecondsSinceEpoch ~/ 1000, 1732000000);
      expect(localAsset.updatedAt, isNot(localAsset.createdAt));
    });
  });
}
