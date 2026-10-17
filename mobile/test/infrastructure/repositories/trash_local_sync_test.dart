import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
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

  LocalSyncService service({Completer<void>? cancellation, LocalAlbumRepository? albumRepository}) => LocalSyncService(
    localAlbumRepository: albumRepository ?? LocalAlbumRepository(ctx.db),
    trashedLocalAssetRepository: TrashedLocalAssetRepository(ctx.db),
    assetMediaRepository: MockAssetMediaRepository(),
    permissionRepository: MockPermissionRepository(),
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
