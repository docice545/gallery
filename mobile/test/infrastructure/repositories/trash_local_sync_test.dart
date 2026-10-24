import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/local_trash.model.dart';
import 'package:immich_mobile/domain/models/pending_local_trash.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mocktail/mocktail.dart';

import '../../medium/repository_context.dart';
import '../../repository.mocks.dart';
import '../../service.mocks.dart';

void main() {
  late MediumRepositoryContext ctx;
  late MockNativeSyncApi native;
  late TimelineRepository timeline;
  late StoreService store;
  final createdAt = DateTime.utc(2026, 9, 1, 12);
  final refreshedAt = createdAt.add(const Duration(days: 1));
  final deletedAt = DateTime.utc(2026, 10, 5, 12);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initializeDateFormatting('en');
  });
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    ctx = MediumRepositoryContext();
    timeline = TimelineRepository(ctx.db);
    store = await StoreService.init(storeRepository: StoreRepository(ctx.db), listenUpdates: false);
    native = MockNativeSyncApi();
    when(() => native.shouldFullSync()).thenAnswer((_) async => false);
    when(() => native.checkpointSync()).thenAnswer((_) async {});
    when(() => native.cancelSync()).thenAnswer((_) async {});
    when(() => native.cancelHashing()).thenAnswer((_) async {});
    await ctx.newUser(id: 'owner');
    await ctx.newAuthUser(id: 'owner');
    await ctx.newLocalAlbum(
      id: 'camera',
      name: 'Camera',
      updatedAt: createdAt,
      backupSelection: BackupSelection.selected,
    );
    await ctx.newLocalAsset(
      id: 'local-still',
      name: 'IMG_1000.JPG',
      checksum: 'still-checksum',
      createdAt: createdAt,
      updatedAt: createdAt,
      width: 4000,
      height: 3000,
      durationMs: 0,
    );
    await ctx.newLocalAlbumAsset(albumId: 'camera', assetId: 'local-still');
    await ctx.newRemoteAsset(
      id: 'remote-still',
      checksum: 'still-checksum',
      ownerId: 'owner',
      createdAt: createdAt,
      deletedAt: deletedAt,
    );
  });
  tearDown(() async {
    await store.dispose();
    await ctx.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  LocalSyncService service({
    Completer<void>? cancellation,
    LocalAlbumRepository? albumRepository,
    AssetMediaRepository? mediaRepository,
    DevicePermissionRepository? permissionRepository,
  }) => LocalSyncService(
    localAlbumRepository: albumRepository ?? LocalAlbumRepository(ctx.db),
    trashedLocalAssetRepository: TrashedLocalAssetRepository(ctx.db),
    assetMediaRepository: mediaRepository ?? MockAssetMediaRepository(),
    permissionRepository: permissionRepository ?? MockPermissionRepository(),
    nativeSyncApi: native,
    cancellation: cancellation,
  );

  PlatformAsset deviceAsset({String id = 'local-still', DateTime? updatedAt}) => PlatformAsset(
    id: id,
    name: 'IMG_1000.JPG',
    type: AssetType.image.index,
    createdAt: createdAt.millisecondsSinceEpoch ~/ 1000,
    updatedAt: (updatedAt ?? refreshedAt).millisecondsSinceEpoch ~/ 1000,
    width: 4000,
    height: 3000,
    durationMs: 0,
    orientation: 0,
    isFavorite: false,
    playbackStyle: PlatformAssetPlaybackStyle.image,
  );

  void configureSnapshot(List<PlatformAsset> assets) {
    when(() => native.getAlbums()).thenAnswer(
      (_) async => [
        PlatformAlbum(
          id: 'camera',
          name: 'Camera',
          updatedAt: refreshedAt.millisecondsSinceEpoch ~/ 1000,
          isCloud: false,
          assetCount: assets.length,
        ),
      ],
    );
    when(() => native.getAssetsForAlbum('camera')).thenAnswer((_) async => assets);
    when(() => native.getAssetIdsForAlbum('camera')).thenAnswer((_) async => assets.map((asset) => asset.id).toList());
    when(() => native.getMediaChanges()).thenAnswer(
      (_) async => SyncDelta(
        hasChanges: true,
        updates: assets,
        deletes: [],
        assetAlbums: {
          for (final asset in assets) asset.id: ['camera'],
        },
      ),
    );
  }

  Future<void> expectTrashAndPhotos({bool photosEmpty = true}) async {
    final photos = await timeline.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 100);
    expect(photos.map((asset) => asset.id), photosEmpty ? isEmpty : ['local-still']);
    final trash = await timeline.trash('owner', GroupAssetsBy.day).assetSource(0, 100);
    expect(trash.map((asset) => asset.id), ['remote-still']);
    expect((trash.single as RemoteAsset).deletedAt, deletedAt);
  }

  for (final full in [true, false]) {
    for (final sameBytes in [true, false]) {
      test(
        '${full ? 'full' : 'delta'} refresh publishes only verified ${sameBytes ? 'same' : 'changed'} content',
        () async {
          configureSnapshot([deviceAsset()]);
          final hashingStarted = Completer<void>();
          final hashResult = Completer<List<HashResult>>();
          when(() => native.hashAssets(['local-still'])).thenAnswer((_) {
            hashingStarted.complete();
            return hashResult.future;
          });
          final sync = service().sync(full: full);
          await hashingStarted.future.timeout(const Duration(seconds: 2));

          // Before native hashing completes, the old verified identity still
          // suppresses its trashed remote twin. No null-checksum tile is published.
          final pending = await ctx.db.localAssetEntity.select().getSingle();
          expect(pending.checksum, 'still-checksum');
          expect(pending.updatedAt, createdAt);
          await expectTrashAndPhotos();
          hashResult.complete([
            HashResult(assetId: 'local-still', hash: sameBytes ? 'still-checksum' : 'edited-checksum'),
          ]);
          await sync;

          final refreshed = await ctx.db.localAssetEntity.select().getSingle();
          expect(refreshed.checksum, sameBytes ? 'still-checksum' : 'edited-checksum');
          expect(refreshed.updatedAt, refreshedAt);
          await expectTrashAndPhotos(photosEmpty: sameBytes);
          verify(() => native.hashAssets(['local-still'])).called(1);
          verify(() => native.checkpointSync()).called(1);
        },
      );
    }

    test('${full ? 'full' : 'delta'} failed hash retains snapshot and skips checkpoint', () async {
      configureSnapshot([deviceAsset()]);
      when(
        () => native.hashAssets(['local-still']),
      ).thenAnswer((_) async => [HashResult(assetId: 'local-still', error: 'Permission denied')]);
      await service().sync(full: full);
      final local = await ctx.db.localAssetEntity.select().getSingle();
      expect(local.checksum, 'still-checksum');
      expect(local.updatedAt, createdAt);
      await expectTrashAndPhotos();
      verifyNever(() => native.checkpointSync());
    });

    test('${full ? 'full' : 'delta'} checksum lookup failure skips publish and checkpoint', () async {
      configureSnapshot([deviceAsset()]);
      await service(albumRepository: _UnavailableHashRevisionsRepository(ctx.db)).sync(full: full);
      final local = await ctx.db.localAssetEntity.select().getSingle();
      expect(local.checksum, 'still-checksum');
      expect(local.updatedAt, createdAt);
      await expectTrashAndPhotos();
      verifyNever(() => native.hashAssets(any()));
      verifyNever(() => native.checkpointSync());
    });

    test('${full ? 'full' : 'delta'} cancellation drains owned hash and skips snapshot/checkpoint', () async {
      configureSnapshot([deviceAsset()]);
      final cancellation = Completer<void>();
      final hashingStarted = Completer<void>();
      final hashResult = Completer<List<HashResult>>();
      when(() => native.hashAssets(['local-still'])).thenAnswer((_) {
        hashingStarted.complete();
        return hashResult.future;
      });
      final sut = service(cancellation: cancellation);
      final sync = sut.sync(full: full);
      await hashingStarted.future.timeout(const Duration(seconds: 2));
      cancellation.complete();
      var drained = false;
      final drain = sut.cancelNativeWork().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      hashResult.completeError(PlatformException(code: 'HASH_CANCELLED'));
      await Future.wait([sync, drain]);
      expect(drained, isTrue);
      final local = await ctx.db.localAssetEntity.select().getSingle();
      expect(local.checksum, 'still-checksum');
      expect(local.updatedAt, createdAt);
      await expectTrashAndPhotos();
      verify(() => native.cancelHashing()).called(1);
      verifyNever(() => native.checkpointSync());
    });
  }

  test('new files keep deferred hashing while unchanged known revisions keep their identity', () async {
    configureSnapshot([deviceAsset(updatedAt: createdAt), deviceAsset(id: 'new-file')]);
    await service().sync();
    final locals = {for (final asset in await ctx.db.localAssetEntity.select().get()) asset.id: asset};
    expect(locals['local-still']!.checksum, 'still-checksum');
    expect(locals['new-file']!.checksum, isNull);
    final photos = await timeline.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 100);
    expect(photos.map((asset) => asset.id), ['new-file']);
    verifyNever(() => native.hashAssets(any()));
    verify(() => native.checkpointSync()).called(1);
  });

  Future<List<PendingLocalTrash>> pendingIntents() async {
    final rows = await (ctx.db.settingsEntity.select()..where((row) => row.key.like('local-trash.v1.%'))).get();
    return rows.map((row) => PendingLocalTrash.fromStored(row.key, row.value!)).toList();
  }

  for (final full in [true, false]) {
    test('${full ? 'full' : 'delta'} discovers a new backup candidate despite deleteWithIds failure', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      final media = MockAssetMediaRepository();
      final permission = MockPermissionRepository();
      when(() => permission.hasManageMediaPermission()).thenAnswer((_) async => true);
      when(() => native.getTrashedAssets()).thenAnswer((_) async => {});
      when(() => media.trashForSync(any())).thenThrow(
        PlatformException(
          code: 'deleteWithIds failed',
          message: 'MediaStore denied request',
          details: 'SecurityException',
        ),
      );
      configureSnapshot([deviceAsset(updatedAt: createdAt), deviceAsset(id: 'new-photo')]);

      final syncService = service(mediaRepository: media, permissionRepository: permission);
      await syncService.sync(full: full);
      verifyNever(() => media.trashForSync(any()));
      await syncService.processPendingTrash();

      final photos = await timeline.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 100);
      expect(photos.map((asset) => asset.id), ['new-photo']);
      final candidates = await BackupRepository(ctx.db).getCandidates('owner', onlyHashed: false);
      expect(candidates.map((asset) => asset.id), ['new-photo']);
      final pending = await pendingIntents();
      expect(pending, hasLength(1));
      expect(pending.single.asset.id, 'local-still');
      expect(pending.single.code, 'deleteWithIds failed');
      expect(pending.single.message, contains('SecurityException'));
      expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
      verify(() => native.checkpointSync()).called(1);

      // Reconstructing the service simulates a new sync owner. The persistent
      // retry deadline, rather than an in-memory flag, prevents an active loop.
      final restartedService = service(mediaRepository: media, permissionRepository: permission);
      await restartedService.sync(full: full);
      await restartedService.processPendingTrash();
      expect((await ctx.db.localAssetEntity.select().get()).where((asset) => asset.id == 'new-photo'), hasLength(1));
      expect((await pendingIntents()).single.attempts, pending.single.attempts);
      verify(() => media.trashForSync(any())).called(1);
      verifyNever(() => media.deleteAll(any(), trash: false));
      verifyNever(() => media.restoreAssetsFromTrash(any()));
    });
  }

  test(
    'pending device trash survives permission loss and a new service completes it after permission returns',
    () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      final repository = TrashedLocalAssetRepository(ctx.db);
      await repository.enqueueTrash(await repository.getToTrash());
      final media = MockAssetMediaRepository();
      final permission = MockPermissionRepository();
      var granted = false;
      when(() => permission.hasManageMediaPermission()).thenAnswer((_) async => granted);
      when(() => native.getTrashedAssets()).thenAnswer((_) async => {});
      when(
        () => media.trashForSync(any()),
      ).thenAnswer((_) async => {'local-still': const LocalTrashResult(code: 'trashed')});
      configureSnapshot([deviceAsset(updatedAt: createdAt), deviceAsset(id: 'new-photo')]);

      final syncService = service(mediaRepository: media, permissionRepository: permission);
      await syncService.sync();
      await syncService.processPendingTrash();

      expect((await pendingIntents()).single.attempts, 0);
      verifyNever(() => media.trashForSync(any()));
      expect((await BackupRepository(ctx.db).getCandidates('owner', onlyHashed: false)).map((asset) => asset.id), [
        'new-photo',
      ]);

      granted = true;
      final restartedService = service(mediaRepository: media, permissionRepository: permission);
      await restartedService.sync();
      await restartedService.processPendingTrash();

      expect(await pendingIntents(), isEmpty);
      expect((await ctx.db.trashedLocalAssetEntity.select().get()).map((asset) => asset.id), ['local-still']);
      expect((await ctx.db.localAssetEntity.select().get()).map((asset) => asset.id), ['new-photo']);
      verify(() => media.trashForSync(any())).called(1);
      verifyNever(() => media.deleteAll(any(), trash: false));
    },
  );

  test('partial Android success removes only verified originals from local state and retains the remainder', () async {
    await Store.put(StoreKey.manageLocalMediaAndroid, true);
    await ctx.newLocalAsset(
      id: 'other',
      name: 'IMG_1000.JPG',
      checksum: 'other-checksum',
      createdAt: createdAt,
      updatedAt: createdAt,
      width: 4000,
      height: 3000,
      durationMs: 0,
    );
    await ctx.newLocalAlbumAsset(albumId: 'camera', assetId: 'other');
    await ctx.newRemoteAsset(id: 'remote-other', checksum: 'other-checksum', ownerId: 'owner', deletedAt: deletedAt);
    final media = MockAssetMediaRepository();
    final permission = MockPermissionRepository();
    when(() => permission.hasManageMediaPermission()).thenAnswer((_) async => true);
    when(() => native.getTrashedAssets()).thenAnswer((_) async => {});
    when(() => media.trashForSync(any())).thenAnswer(
      (_) async => {
        'local-still': const LocalTrashResult(code: 'trashed'),
        'other': const LocalTrashResult(code: 'missing', message: 'ID is not visible in MediaStore'),
      },
    );
    configureSnapshot([
      deviceAsset(updatedAt: createdAt),
      deviceAsset(id: 'other', updatedAt: createdAt),
      deviceAsset(id: 'new-photo'),
    ]);

    final syncService = service(mediaRepository: media, permissionRepository: permission);
    await syncService.sync();
    verifyNever(() => media.trashForSync(any()));
    await syncService.processPendingTrash();

    expect((await ctx.db.trashedLocalAssetEntity.select().get()).map((asset) => asset.id), ['local-still']);
    expect(
      (await ctx.db.localAssetEntity.select().get()).map((asset) => asset.id),
      unorderedEquals(['other', 'new-photo']),
    );
    final pending = await pendingIntents();
    expect(pending, hasLength(1));
    expect(pending.single.asset.id, 'other');
    expect(pending.single.code, 'missing');
    expect((await BackupRepository(ctx.db).getCandidates('owner', onlyHashed: false)).map((asset) => asset.id), [
      'new-photo',
    ]);
    verifyNever(() => media.deleteAll(any(), trash: false));
  });

  test('cancelling local sync without an owned hash does not cancel another hashing job', () async {
    await service().cancelNativeWork();
    verify(() => native.cancelSync()).called(1);
    verifyNever(() => native.cancelHashing());
  });

  test('native hashing errors retain the previous snapshot for a later successful retry', () async {
    configureSnapshot([deviceAsset()]);
    when(() => native.hashAssets(['local-still'])).thenThrow(PlatformException(code: 'Permission denied'));
    await service().sync();
    expect((await ctx.db.localAssetEntity.select().getSingle()).updatedAt, createdAt);
    await expectTrashAndPhotos();
    verifyNever(() => native.checkpointSync());

    when(
      () => native.hashAssets(['local-still']),
    ).thenAnswer((_) async => [HashResult(assetId: 'local-still', hash: 'still-checksum')]);
    await service().sync();
    expect((await ctx.db.localAssetEntity.select().getSingle()).updatedAt, refreshedAt);
    await expectTrashAndPhotos();
    verify(() => native.checkpointSync()).called(1);
  });

  test('a valid hash arriving after cancellation cannot publish a new snapshot', () async {
    configureSnapshot([deviceAsset()]);
    final cancellation = Completer<void>();
    final hashingStarted = Completer<void>();
    final hashResult = Completer<List<HashResult>>();
    when(() => native.hashAssets(['local-still'])).thenAnswer((_) {
      hashingStarted.complete();
      return hashResult.future;
    });
    final sut = service(cancellation: cancellation);
    final sync = sut.sync();
    await hashingStarted.future.timeout(const Duration(seconds: 2));
    cancellation.complete();
    final drain = sut.cancelNativeWork();
    hashResult.complete([HashResult(assetId: 'local-still', hash: 'edited-checksum')]);
    await Future.wait([sync, drain]);
    final local = await ctx.db.localAssetEntity.select().getSingle();
    expect(local.checksum, 'still-checksum');
    expect(local.updatedAt, createdAt);
    await expectTrashAndPhotos();
    verifyNever(() => native.checkpointSync());
  });
}

class _UnavailableHashRevisionsRepository extends LocalAlbumRepository {
  _UnavailableHashRevisionsRepository(super.attachedDatabase);

  @override
  Future<Map<String, DateTime>> getHashedAssetRevisions(Iterable<String> assetIds) async {
    throw StateError('Checksum revision lookup unavailable');
  }
}
