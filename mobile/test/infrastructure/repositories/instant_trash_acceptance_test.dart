import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart' show kMobileMetadataKey;
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:openapi/api.dart' as api;

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late RemoteAssetRepository remote;
  late SyncStreamRepository sync;
  const endpoint = 'https://gallery.invalid/api';
  final deletedAt = DateTime.utc(2026, 11, 1);

  setUpAll(() => initializeDateFormatting('en'));
  setUp(() async {
    ctx = MediumRepositoryContext();
    await ctx.newUser(id: 'owner');
    await ctx.newAuthUser(id: 'owner');
    await StoreRepository(ctx.db).upsert(StoreKey.serverEndpoint, endpoint);
    await ctx.newRemoteAsset(id: 'accepted', ownerId: 'owner', checksum: 'accepted-checksum', deletedAt: deletedAt);
    remote = RemoteAssetRepository(ctx.db);
    sync = SyncStreamRepository(ctx.db);
  });
  tearDown(() => ctx.dispose());

  Future<Map<String, dynamic>?> marker({Drift? db, String owner = 'owner', String id = 'accepted'}) async {
    final database = db ?? ctx.db;
    final row = await (database.settingsEntity.select()..where((row) => row.key.like('sync.trash-reset.%/$owner/$id')))
        .getSingleOrNull();
    final value = row?.value;
    return value == null ? null : jsonDecode(value) as Map<String, dynamic>;
  }

  Map<String, dynamic> payload({
    DateTime? deleted,
    String checksum = 'accepted-checksum',
    String owner = 'owner',
    bool v2 = true,
  }) => {
    'id': 'accepted',
    'ownerId': owner,
    'checksum': checksum,
    'originalFileName': 'photo.jpg',
    'type': 'IMAGE',
    'isFavorite': false,
    'fileCreatedAt': deletedAt.toIso8601String(),
    'fileModifiedAt': deletedAt.toIso8601String(),
    'createdAt': deletedAt.toIso8601String(),
    'localDateTime': deletedAt.toIso8601String(),
    'visibility': 'timeline',
    'isEdited': false,
    'duration': v2 ? 0 : null,
    'deletedAt': deleted?.toIso8601String(),
    'height': 800,
    'width': 600,
    'libraryId': null,
    'livePhotoVideoId': null,
    'stackId': null,
    'thumbhash': null,
  };

  test(
    'accepted pending deletion immediately empties reactive Trash but preserves Samsung original and backup fence',
    () async {
      await ctx.newLocalAsset(id: 'samsung-original', checksum: 'accepted-checksum');
      await ctx.newLocalAlbum(id: 'camera', backupSelection: BackupSelection.selected);
      await ctx.newLocalAlbumAsset(albumId: 'camera', assetId: 'samsung-original');
      final timeline = TimelineRepository(ctx.db);
      final stream = StreamIterator(timeline.trash('owner', GroupAssetsBy.day).bucketSource());
      addTearDown(stream.cancel);
      expect(await stream.moveNext().timeout(const Duration(seconds: 2)), isTrue);
      expect(stream.current.fold(0, (count, bucket) => count + bucket.assetCount), 1);
      final snapshots = await remote.beginPermanentDeletion(['accepted']);
      final changed = stream.moveNext();
      await remote.acceptPermanentDeletion(snapshots, ['accepted'], []);
      expect(await changed.timeout(const Duration(seconds: 2)), isTrue);
      expect(stream.current, isEmpty);
      expect(await remote.getTrashIds('owner'), isEmpty);
      expect(await remote.get('accepted'), isNull);
      expect((await marker())?['permanent'], isTrue);
      expect((await marker())?['permanentComplete'], isNot(true));
      expect((await marker())?['phase'], 'uncertain');
      expect((await ctx.db.localAssetEntity.select().get()).single.id, 'samsung-original');
      expect(await remote.getDeletionLocalIds(['accepted']), ['samsung-original']);
      expect(await BackupRepository(ctx.db).getCandidates('owner'), isEmpty);
      expect(await timeline.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 20), isEmpty);
      // A different account must not inherit this owner's upload exclusion.
      expect((await BackupRepository(ctx.db).getCandidates('other')).map((asset) => asset.id), ['samsung-original']);
      await expectLater(remote.beginTrashOperation(['accepted'], restore: true), throwsStateError);
    },
  );

  test('acceptance retires only acknowledged IDs and leaves a rejected or newly arrived item in Trash', () async {
    await ctx.newRemoteAsset(id: 'rejected', ownerId: 'owner', deletedAt: deletedAt);
    final snapshots = await remote.beginPermanentDeletion(['accepted', 'rejected']);
    await ctx.newRemoteAsset(id: 'new-trash', ownerId: 'owner', deletedAt: deletedAt);
    await remote.acceptPermanentDeletion(snapshots, ['accepted'], []);
    await remote.completeTrashOperation(
      snapshots.where((item) => item.id == 'rejected').toList(),
      success: false,
      definiteFailure: true,
    );
    expect(await remote.getTrashIds('owner'), unorderedEquals(['rejected', 'new-trash']));
    expect((await marker(id: 'rejected'))?['permanent'], isNot(true));
  });

  for (final acceptedCount in [500, 307]) {
    test(
      '500-item selection retires exactly $acceptedCount durable receipts and retains every other Trash row',
      () async {
        final selected = ['accepted', for (var index = 1; index < 500; index++) 'selected-$index'];
        await ctx.db.transaction(() async {
          for (final id in selected.skip(1)) {
            await ctx.newRemoteAsset(id: id, ownerId: 'owner', checksum: 'checksum-$id', deletedAt: deletedAt);
          }
        });
        final snapshots = await remote.beginPermanentDeletion(selected);
        expect(snapshots, hasLength(500));
        // A photograph arriving after the captured selection is not authorized
        // merely because the user confirmed all previously selected objects.
        await ctx.newRemoteAsset(id: 'outside-selection', ownerId: 'owner', deletedAt: deletedAt);
        final stream = StreamIterator(TimelineRepository(ctx.db).trash('owner', GroupAssetsBy.day).bucketSource());
        addTearDown(stream.cancel);
        expect(await stream.moveNext().timeout(const Duration(seconds: 2)), isTrue);
        expect(stream.current.fold(0, (count, bucket) => count + bucket.assetCount), 501);

        final accepted = selected.take(acceptedCount).toList();
        final changed = stream.moveNext();
        await remote.acceptPermanentDeletion(snapshots, accepted, const []);
        expect(await changed.timeout(const Duration(seconds: 2)), isTrue);
        expect(stream.current.fold(0, (count, bucket) => count + bucket.assetCount), 501 - acceptedCount);
        await remote.completeTrashOperation(
          snapshots.where((snapshot) => !accepted.contains(snapshot.id)).toList(),
          success: false,
          definiteFailure: true,
        );

        expect(
          await remote.getTrashIds('owner'),
          unorderedEquals([...selected.skip(acceptedCount), 'outside-selection']),
        );
        expect((await marker(id: accepted.last))?['permanent'], isTrue);
        expect((await marker(id: accepted.last))?['permanentComplete'], isNot(true));
        expect(await marker(id: 'outside-selection'), isNull);
        expect((await sync.getPendingTrashOperations()).map((snapshot) => snapshot.id), unorderedEquals(accepted));
        await expectLater(remote.beginTrashOperation(accepted, restore: true), throwsStateError);
        final restorable = selected.skip(acceptedCount).toList();
        if (restorable.isNotEmpty) {
          expect(await remote.beginTrashOperation(restorable, restore: true), hasLength(restorable.length));
        }
      },
    );
  }

  for (final alreadyReplied in [false, true]) {
    test(
      'authoritative acceptance wins a stale Restore ${alreadyReplied ? 'already completed' : 'in flight'}',
      () async {
        final deleting = await remote.beginPermanentDeletion(['accepted']);
        // An older client or optimistic operation can replace a revision before
        // the permanent server response returns. It cannot undo server intent.
        await remote.trash(['accepted']);
        final restoring = await remote.beginTrashOperation(['accepted'], restore: true);
        if (alreadyReplied) {
          await remote.completeTrashOperation(restoring, success: true);
        }
        await remote.acceptPermanentDeletion(deleting, ['accepted'], []);
        await remote.completeTrashOperation(restoring, success: true);
        expect(await remote.get('accepted'), isNull);
        expect((await marker())?['permanent'], isTrue);
        await expectLater(remote.beginTrashOperation(['accepted'], restore: true), throwsStateError);
      },
    );
  }

  test('unknown network outcome blocks Restore until a definitive no-intent receipt rolls it back', () async {
    final snapshots = await remote.beginPermanentDeletion(['accepted']);
    await remote.completeTrashOperation(snapshots, success: false);
    expect((await remote.get('accepted'))!.isTrashed, isTrue);
    expect((await marker())?['permanent'], isNot(true));
    await expectLater(remote.beginTrashOperation(['accepted'], restore: true), throwsStateError);
    final checked = (await sync.getPendingTrashOperations()).single;
    await sync.resolvePermanentDeletion(checked, accepted: false);
    expect((await marker())?['operation'], isNull);
    expect(await remote.beginTrashOperation(['accepted'], restore: true), hasLength(1));
  });

  test('a late no-intent receipt never releases an already accepted pending or failed deletion', () async {
    final snapshots = await remote.beginPermanentDeletion(['accepted']);
    await remote.acceptPermanentDeletion(snapshots, ['accepted'], []);
    final pending = (await sync.getPendingTrashOperations()).single;
    await sync.resolvePermanentDeletion(pending, accepted: false);
    await remote.acceptPermanentDeletion(snapshots, ['accepted'], []);
    expect(await remote.get('accepted'), isNull);
    expect((await marker())?['permanent'], isTrue);
    expect((await marker())?['permanentComplete'], isNot(true));
    await remote.acceptPermanentDeletion(snapshots, ['accepted'], ['accepted']);
    expect((await marker())?['permanentComplete'], isTrue);
    await remote.acceptPermanentDeletion(snapshots, ['accepted'], []);
    expect((await marker())?['permanentComplete'], isTrue);
    expect(await sync.getPendingTrashOperations(), isEmpty);
  });

  for (final v2 in [false, true]) {
    test(
      'accepted ${v2 ? 'V2' : 'V1'} replay and reset cannot return pending or failed assets to any timeline',
      () async {
        final snapshots = await remote.beginPermanentDeletion(['accepted']);
        await remote.acceptPermanentDeletion(snapshots, ['accepted'], []);
        for (final deleted in [null, deletedAt]) {
          if (v2) {
            await sync.updateAssetsV2([api.SyncAssetV2.fromJson(payload(deleted: deleted))!]);
          } else {
            await sync.updateAssetsV1([api.SyncAssetV1.fromJson(payload(deleted: deleted, v2: false))!]);
          }
        }
        await sync.reset();
        await ctx.newUser(id: 'owner');
        await ctx.newAuthUser(id: 'owner');
        if (v2) {
          await sync.updateAssetsV2([api.SyncAssetV2.fromJson(payload(deleted: deletedAt))!]);
        } else {
          await sync.updateAssetsV1([api.SyncAssetV1.fromJson(payload(deleted: deletedAt, v2: false))!]);
        }
        expect(await remote.getTrashIds('owner'), isEmpty);
        expect(await remote.get('accepted'), isNull);
        expect(await sync.watchTrashedAssetIds().first, contains('accepted'));
        expect((await marker())?['permanent'], isTrue);
      },
    );
  }

  test('acceptance cannot delete a different owner or checksum replacement or another server', () async {
    final snapshots = await remote.beginPermanentDeletion(['accepted']);
    await ctx.db.remoteAssetEntity.deleteAll();
    await ctx.newUser(id: 'other');
    await ctx.newRemoteAsset(id: 'accepted', ownerId: 'other', checksum: 'other-content');
    await remote.acceptPermanentDeletion(snapshots, ['accepted'], ['accepted']);
    expect((await remote.get('accepted'))!.ownerId, 'other');
    expect((await marker())?['permanent'], isNot(true));
    await ctx.db.remoteAssetEntity.deleteAll();
    await ctx.newRemoteAsset(id: 'accepted', ownerId: 'owner', checksum: 'replacement');
    await remote.acceptPermanentDeletion(snapshots, ['accepted'], []);
    expect((await remote.get('accepted'))!.checksum, 'replacement');
    await ctx.db.remoteAssetEntity.deleteAll();
    await ctx.newRemoteAsset(id: 'accepted', ownerId: 'owner', checksum: 'accepted-checksum');
    await StoreRepository(ctx.db).upsert(StoreKey.serverEndpoint, 'https://other.invalid/api');
    await remote.acceptPermanentDeletion(snapshots, ['accepted'], []);
    expect(await remote.get('accepted'), isNotNull);
  });

  test('accepted parent suppresses only its own delayed FK child events and album thumbnail', () async {
    await ctx.newRemoteAlbum(id: 'album', ownerId: 'owner');
    final snapshots = await remote.beginPermanentDeletion(['accepted']);
    await remote.acceptPermanentDeletion(snapshots, ['accepted'], []);
    await sync.updateAlbumToAssetsV1([api.SyncAlbumToAssetV1(albumId: 'album', assetId: 'accepted')]);
    final exif = <String, dynamic>{
      for (final key in [
        'city',
        'country',
        'dateTimeOriginal',
        'description',
        'exifImageHeight',
        'exifImageWidth',
        'exposureTime',
        'fNumber',
        'fileSizeInByte',
        'focalLength',
        'fps',
        'iso',
        'latitude',
        'lensModel',
        'longitude',
        'make',
        'model',
        'modifyDate',
        'orientation',
        'profileDescription',
        'projectionType',
        'rating',
        'state',
        'timeZone',
      ])
        key: null,
      'assetId': 'accepted',
    };
    await sync.updateAssetsExifV1([api.SyncAssetExifV1.fromJson(exif)!]);
    await sync.updateAssetsMetadataV1([api.SyncAssetMetadataV1(assetId: 'accepted', key: kMobileMetadataKey)]);
    final edit = api.SyncAssetEditV1(id: 'edit', assetId: 'accepted', action: api.AssetEditAction.crop, sequence: 0);
    await sync.updateAssetEditsV1([edit]);
    await sync.replaceAssetEditsV1('accepted', [edit]);
    final face = <String, dynamic>{
      'id': 'face',
      'assetId': 'accepted',
      'personId': null,
      'imageWidth': 600,
      'imageHeight': 800,
      'boundingBoxX1': 0,
      'boundingBoxY1': 0,
      'boundingBoxX2': 1,
      'boundingBoxY2': 1,
      'sourceType': 'machine-learning',
      'deletedAt': null,
      'isVisible': true,
    };
    await sync.updateAssetFacesV1([api.SyncAssetFaceV1.fromJson(face)!]);
    await sync.updateAssetFacesV2([api.SyncAssetFaceV2.fromJson(face)!]);
    await sync.updateAssetFacesV3([api.SyncAssetFaceV2.fromJson(face)!]);
    await sync.updateAssetOcrV1([
      api.SyncAssetOcrV1(
        assetId: 'accepted',
        id: 'ocr',
        boxScore: 1,
        textScore: 1,
        text: 'synthetic',
        isVisible: true,
        x1: 0,
        x2: 1,
        x3: 1,
        x4: 0,
        y1: 0,
        y2: 0,
        y3: 1,
        y4: 1,
      ),
    ]);
    await sync.updateAlbumsV2([
      api.SyncAlbumV2(
        id: 'album',
        name: 'Album',
        description: '',
        order: api.AssetOrder.asc,
        isActivityEnabled: false,
        thumbnailAssetId: 'accepted',
        createdAt: deletedAt,
        updatedAt: deletedAt,
      ),
    ]);
    await sync.updateMemoryAssetsV1([api.SyncMemoryAssetV1(memoryId: 'memory', assetId: 'accepted')]);
    await sync.flushDeferredMemoryAssetsV1();
    await sync.updateMemoryAssetsV2([api.SyncMemoryAssetV1(memoryId: 'memory', assetId: 'accepted')]);
    expect(await ctx.db.remoteAlbumAssetEntity.select().get(), isEmpty);
    expect(await ctx.db.remoteExifEntity.select().get(), isEmpty);
    expect(await ctx.db.assetEditEntity.select().get(), isEmpty);
    expect(await ctx.db.assetFaceEntity.select().get(), isEmpty);
    expect(await ctx.db.assetOcrEntity.select().get(), isEmpty);
    expect((await ctx.db.remoteAlbumEntity.select().get()).single.thumbnailAssetId, isNull);
    expect(
      await (ctx.db.settingsEntity.select()..where((row) => row.key.like('sync.memory-links.v2.%'))).get(),
      isEmpty,
    );
    // Genuine missing-parent errors remain visible; only explicit permanent
    // receipts permit ignoring their child payloads.
    await expectLater(
      sync.updateAlbumToAssetsV1([api.SyncAlbumToAssetV1(albumId: 'album', assetId: 'ordinary-missing')]),
      throwsA(isA<SqliteException>()),
    );
  });

  test('logical delete events retain pending acceptance without claiming physical completion', () async {
    await sync.retainPermanentDeletion(['accepted'], complete: false);
    await sync.deleteAssetsV1([api.SyncAssetDeleteV1(assetId: 'accepted')]);
    expect(await remote.get('accepted'), isNull);
    expect((await marker())!['permanent'], isTrue);
    expect((await marker())!['permanentComplete'], isFalse);
    final pending = (await sync.getPendingTrashOperations()).single;
    await sync.updateAssetsV2([api.SyncAssetV2.fromJson(payload(deleted: deletedAt))!]);
    expect(await remote.get('accepted'), isNull);
    await sync.resolvePermanentDeletion(pending, accepted: true, complete: true);
    expect((await marker())!['permanentComplete'], isTrue);
    expect(await sync.getPendingTrashOperations(), isEmpty);
  });

  test('accepted intent survives file-backed SQLite reopen without physical completion', () async {
    final directory = await Directory.systemTemp.createTemp('foto-instant-trash-');
    final file = File('${directory.path}/cache.sqlite');
    var cache = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    addTearDown(() async {
      await cache.close();
      await directory.delete(recursive: true);
    });
    await cache.into(cache.userEntity).insert(await ctx.db.userEntity.select().getSingle());
    await cache.into(cache.authUserEntity).insert(await ctx.db.authUserEntity.select().getSingle());
    await cache.into(cache.remoteAssetEntity).insert(await ctx.db.remoteAssetEntity.select().getSingle());
    await StoreRepository(cache).upsert(StoreKey.serverEndpoint, endpoint);
    final before = RemoteAssetRepository(cache);
    final snapshots = await before.beginPermanentDeletion(['accepted']);
    await before.acceptPermanentDeletion(snapshots, ['accepted'], []);
    await cache.close();
    cache = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    final reloaded = SyncStreamRepository(cache);
    await reloaded.recoverPendingTrashOperations();
    expect(await RemoteAssetRepository(cache).get('accepted'), isNull);
    final pending = (await reloaded.getPendingTrashOperations()).single;
    expect(jsonDecode(pending.retainedValue!)['permanent'], isTrue);
    expect(jsonDecode(pending.retainedValue!)['permanentComplete'], isNot(true));
    await reloaded.updateAssetsV2([api.SyncAssetV2.fromJson(payload(deleted: deletedAt))!]);
    expect(await RemoteAssetRepository(cache).get('accepted'), isNull);
    await reloaded.resolvePermanentDeletion(pending, accepted: true, complete: true);
    expect(await reloaded.getPendingTrashOperations(), isEmpty);
  });
}
