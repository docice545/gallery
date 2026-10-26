import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:openapi/api.dart' as api;

import '../../medium/repository_context.dart';

void main() {
  const owner = 'owner';
  const id = '8dd6007e-f11b-4bf8-bc3a-121794f37303';
  const endpoint = 'https://example.test/photos/api';
  late MediumRepositoryContext ctx;
  late StoreService store;
  late RemoteAssetRepository repository;
  var closed = false;

  setUp(() async {
    closed = false;
    ctx = MediumRepositoryContext();
    repository = RemoteAssetRepository(ctx.db);
    store = await StoreService.init(storeRepository: StoreRepository(ctx.db), listenUpdates: false);
    await store.put(StoreKey.serverEndpoint, endpoint);
    await ctx.newUser(id: owner);
    await ctx.newUser(id: 'other');
    await ctx.newAuthUser(id: owner);
    await ctx.newRemoteAsset(id: id, ownerId: owner, checksum: 'matching-checksum');
    await ctx.newLocalAsset(id: 'local-original', checksum: 'matching-checksum');
    await ctx.newRemoteAlbum(id: 'album', ownerId: owner, thumbnailAssetId: id);
    await ctx.newRemoteAlbumAsset(albumId: 'album', assetId: id);
  });

  tearDown(() async {
    if (!closed) {
      await store.dispose();
      await ctx.dispose();
    }
  });

  test('confirmed deletion removes only remote cache and cascades associations atomically', () async {
    final watched = <Object?>[];
    final subscription = repository.watch(id).listen(watched.add);
    addTearDown(subscription.cancel);
    expect(await repository.get(id), isNotNull);
    expect(await repository.retireConfirmedDeletedAsset(id, ownerId: owner, endpoint: endpoint), isTrue);
    expect(await repository.get(id), isNull);
    expect(await ctx.db.select(ctx.db.remoteAlbumAssetEntity).get(), isEmpty);
    expect(await ctx.db.select(ctx.db.localAssetEntity).get(), hasLength(1));
    expect(await ctx.db.select(ctx.db.trashedLocalAssetEntity).get(), isEmpty);
    // No native MediaStore API or local deletion is used in this repository.
    await Future<void>.delayed(Duration.zero);
    expect(watched.last, isNull);
    expect(await repository.retireConfirmedDeletedAsset(id, ownerId: owner, endpoint: endpoint), isFalse);
  });

  test('wrong owner, old endpoint and logged-out database cannot retire a row', () async {
    expect(await repository.retireConfirmedDeletedAsset(id, ownerId: 'other', endpoint: endpoint), isFalse);
    expect(await repository.retireConfirmedDeletedAsset(id, ownerId: owner, endpoint: 'https://old.test/api'), isFalse);
    await ctx.db.delete(ctx.db.authUserEntity).go();
    expect(await repository.retireConfirmedDeletedAsset(id, ownerId: owner, endpoint: endpoint), isFalse);
    expect(await repository.get(id), isNotNull);
    expect(await ctx.db.select(ctx.db.remoteAlbumAssetEntity).get(), hasLength(1));
  });

  test('reopening the on-disk database preserves permanent suppression and the original', () async {
    expect(await repository.retireConfirmedDeletedAsset(id, ownerId: owner, endpoint: endpoint), isTrue);
    expect(await ctx.db.select(ctx.db.settingsEntity).get(), hasLength(1));
    final directory = await Directory.systemTemp.createTemp('foto-confirmed-deletion-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/local.db');
    await ctx.db.customStatement('VACUUM INTO ?', [file.path]);
    await store.dispose();
    await ctx.dispose();
    closed = true;
    final reopened = Drift(drift.DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    addTearDown(reopened.close);
    repository = RemoteAssetRepository(reopened);
    expect(await repository.get(id), isNull);
    final rows = await (reopened.select(
      reopened.settingsEntity,
    )..where((row) => row.key.like('sync.trash-reset.%'))).get();
    final state = rows.map((row) => jsonDecode(row.value!) as Map<String, dynamic>).single;
    expect(state['id'], id);
    expect(state['ownerId'], owner);
    expect(state['permanent'], isTrue);
    expect(state['permanentComplete'], isTrue);
    expect(state['checksum'], 'matching-checksum');
    expect(await reopened.select(reopened.localAssetEntity).get(), hasLength(1));
    // The same persisted marker is consumed by normal backfill/reset sync.
    expect(await reopened.syncStreamRepository.getDeletionLocalIds([id]), ['local-original']);
    // An out-of-order pre-deletion payload after restart must not recreate a
    // remote thumbnail or duplicate the still-present local original.
    final captured = DateTime.utc(2026, 1, 1);
    await reopened.syncStreamRepository.updateAssetsV1([
      api.SyncAssetV1(
        id: id,
        checksum: 'matching-checksum',
        originalFileName: 'original.jpg',
        type: api.AssetTypeEnum.IMAGE,
        ownerId: owner,
        isFavorite: false,
        isEdited: false,
        fileCreatedAt: captured,
        fileModifiedAt: captured,
        createdAt: captured,
        localDateTime: captured,
        visibility: api.AssetVisibility.timeline,
        width: 100,
        height: 200,
        deletedAt: null,
        duration: null,
        libraryId: null,
        livePhotoVideoId: null,
        stackId: null,
        thumbhash: null,
      ),
    ]);
    expect(await repository.get(id), isNull);
    expect(await reopened.select(reopened.localAssetEntity).get(), hasLength(1));
  });

  test('ordinary Restore retention still excludes an active asset', () async {
    final snapshots = await ctx.db.syncStreamRepository.updateRetainedTrash(
      [id],
      DateTime.now(),
      preserveExistingDates: true,
    );
    expect(snapshots, isEmpty);
    expect(await ctx.db.select(ctx.db.settingsEntity).get(), isEmpty);
    expect(await repository.get(id), isNotNull);
  });

  test('a delayed confirmation for a previous canonical server cannot mutate the new library', () async {
    await store.put(StoreKey.serverEndpoint, 'https://other.test/api');
    expect(await repository.retireConfirmedDeletedAsset(id, ownerId: owner, endpoint: endpoint), isFalse);
    expect(await repository.get(id), isNotNull);
    expect(await ctx.db.select(ctx.db.settingsEntity).get(), isEmpty);
  });
}
