import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_temporal_scope.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:openapi/api.dart' as api;

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late SyncStreamRepository sync;
  late TimelineRepository timeline;
  final createdAt = DateTime.utc(2026, 9, 1, 12);
  final deletedAt = DateTime.utc(2026, 10, 5, 12);

  setUpAll(() => initializeDateFormatting('en'));
  setUp(() async {
    ctx = MediumRepositoryContext();
    sync = SyncStreamRepository(ctx.db);
    timeline = TimelineRepository(ctx.db);
    await ctx.newUser(id: 'owner');
    await ctx.newAuthUser(id: 'owner');
    await StoreRepository(ctx.db).upsert(StoreKey.serverEndpoint, 'https://gallery.invalid/api');
  });
  tearDown(() => ctx.dispose());

  test('search visibility watches durable pending Trash across missing rows and definite rejection', () async {
    await ctx.newRemoteAsset(id: 'still', ownerId: 'owner');
    final ids = StreamIterator(sync.watchTrashedAssetIds());
    addTearDown(ids.cancel);
    expect(await ids.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(ids.current, isEmpty);
    final snapshots = await RemoteAssetRepository(ctx.db).beginTrashOperation(['still'], restore: false);
    expect(await ids.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(ids.current, {'still'});
    // Sync reset can remove the row before replay; the durable marker remains.
    await ctx.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('still'));
    expect(await ids.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(ids.current, {'still'});
    expect(await SyncStreamRepository(ctx.db).watchTrashedAssetIds().first, {'still'});
    await sync.completeTrashOperation(snapshots, success: false, definiteFailure: true);
    expect(await ids.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    // The reset row is still absent: wait for replay instead of resurrecting a
    // cached result based solely on the removed marker.
    expect(ids.current, {'still'});
    await ctx.newRemoteAsset(id: 'still', ownerId: 'owner');
    expect(await ids.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(ids.current, isEmpty);
  });

  test('permanent deletion cannot reveal an old cached result when its Trash marker is cleared', () async {
    await ctx.newRemoteAsset(id: 'still', ownerId: 'owner');
    final remote = RemoteAssetRepository(ctx.db);
    await remote.trash(['still']);
    final ids = StreamIterator(sync.watchTrashedAssetIds());
    addTearDown(ids.cancel);
    expect(await ids.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(ids.current, {'still'});
    await remote.deleteAssets(['still']);
    expect(await ids.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(ids.current, {'still'});
    expect(await remote.get('still'), isNull);
    // An unrelated subsequent DB change must not resurrect the deleted tile.
    await ctx.newRemoteAsset(id: 'other', ownerId: 'owner');
    expect(await ids.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(ids.current, {'still'});
  });

  test('search visibility removes and reapplies the marker for Restore followed by another Trash', () async {
    await ctx.newRemoteAsset(id: 'still', ownerId: 'owner');
    final remote = RemoteAssetRepository(ctx.db);
    await remote.trash(['still']);
    final ids = StreamIterator(sync.watchTrashedAssetIds());
    addTearDown(ids.cancel);
    expect(await ids.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(ids.current, {'still'});
    final restore = await remote.beginTrashOperation(['still'], restore: true);
    expect(await ids.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(ids.current, isEmpty);
    await remote.beginTrashOperation(['still'], restore: false);
    expect(await ids.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(ids.current, {'still'});
    await remote.completeTrashOperation(restore, success: true);
    expect(await sync.watchTrashedAssetIds().first, {'still'});
  });

  Map<String, Object?> payload({String? libraryId, DateTime? trashDate}) => {
    'id': 'still',
    'checksum': 'still-checksum',
    'originalFileName': 'IMG_1000.JPG',
    'type': 'IMAGE',
    'ownerId': 'owner',
    'isFavorite': false,
    'fileCreatedAt': createdAt.toIso8601String(),
    'fileModifiedAt': createdAt.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'localDateTime': createdAt.toIso8601String(),
    'visibility': 'timeline',
    'width': 4000,
    'height': 3000,
    'deletedAt': trashDate?.toIso8601String(),
    'duration': null,
    'libraryId': libraryId,
    'livePhotoVideoId': 'motion',
    'stackId': null,
    'thumbhash': null,
    'isEdited': false,
  };

  Future<void> stream(Map<String, Object?> json, {required bool v2}) async {
    if (v2) {
      final dto = api.SyncAssetV2.fromJson(json)!;
      expect(dto.deletedAt, json['deletedAt'] == null ? null : deletedAt);
      await sync.updateAssetsV2([dto]);
    } else {
      final dto = api.SyncAssetV1.fromJson(json)!;
      expect(dto.deletedAt, json['deletedAt'] == null ? null : deletedAt);
      await sync.updateAssetsV1([dto]);
    }
  }

  for (final v2 in [false, true]) {
    test('offline index timestamp is not user Trash (v2=$v2)', () async {
      final json = payload(trashDate: deletedAt)..['isTrashed'] = false;
      await stream(json, v2: v2);
      expect(await RemoteAssetRepository(ctx.db).getTrashIds('owner'), isEmpty);
      expect(await timeline.trash('owner', GroupAssetsBy.day).assetSource(0, 100), isEmpty);
      expect((await RemoteAssetRepository(ctx.db).get('still'))!.isTrashed, isFalse);
      expect(await sync.getRestoreCandidates({'still': 'owner'}), isEmpty);
      // A cache reset must not turn index-only availability into a user deletion
      // marker that suppresses local backup or outlives the index row.
      await sync.reset();
      expect(await sync.getRetainedTrashIds('owner'), isEmpty);
      await ctx.newUser(id: 'owner');
      await ctx.newAuthUser(id: 'owner');
      await stream(json, v2: v2);
      expect(await RemoteAssetRepository(ctx.db).getTrashIds('owner'), isEmpty);
    });

    test('definite rejected Trash restores index availability without retaining user Trash (v2=$v2)', () async {
      final json = payload(trashDate: deletedAt)..['isTrashed'] = false;
      await stream(json, v2: v2);
      final snapshots = await RemoteAssetRepository(ctx.db).beginTrashOperation(['still'], restore: false);
      expect(await RemoteAssetRepository(ctx.db).getTrashIds('owner'), ['still']);
      await sync.completeTrashOperation(snapshots, success: false, definiteFailure: true);
      expect(await sync.getRetainedTrashIds('owner'), isEmpty);
      expect(await RemoteAssetRepository(ctx.db).getTrashIds('owner'), isEmpty);
      expect((await RemoteAssetRepository(ctx.db).get('still'))!.isIndexTombstone, isTrue);
      await stream(json, v2: v2);
      expect(await RemoteAssetRepository(ctx.db).getTrashIds('owner'), isEmpty);
    });

    test('a delayed index snapshot cannot clear pending user Trash (v2=$v2)', () async {
      await stream(payload(), v2: v2);
      final snapshots = await RemoteAssetRepository(ctx.db).beginTrashOperation(['still'], restore: false);
      await stream(payload(trashDate: deletedAt)..['isTrashed'] = false, v2: v2);
      expect(await RemoteAssetRepository(ctx.db).getTrashIds('owner'), ['still']);
      expect((await RemoteAssetRepository(ctx.db).get('still'))!.isTrashed, isTrue);
      await sync.completeTrashOperation(snapshots, success: true);
      await stream(payload(trashDate: deletedAt)..['isTrashed'] = false, v2: v2);
      expect(await RemoteAssetRepository(ctx.db).getTrashIds('owner'), ['still']);
    });
  }

  test('index-only cache flag survives an actual SQLite close and reopen', () async {
    final directory = await Directory.systemTemp.createTemp('gallery-index-test-');
    final file = File('${directory.path}/cache.sqlite');
    var cache = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    addTearDown(() async {
      await cache.close();
      await directory.delete(recursive: true);
    });
    await cache.into(cache.userEntity).insert(await ctx.db.select(ctx.db.userEntity).getSingle());
    final dto = api.SyncAssetV2.fromJson(payload(trashDate: deletedAt)..['isTrashed'] = false)!;
    await SyncStreamRepository(cache).updateAssetsV2([dto]);
    await cache.close();
    cache = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    expect(await RemoteAssetRepository(cache).getTrashIds('owner'), isEmpty);
    expect((await RemoteAssetRepository(cache).get('still'))!.isTrashed, isFalse);
  });

  List<TimelineQuery> photosQueries() => [
    timeline.main(['owner'], 'owner', GroupAssetsBy.day),
    timeline.main(['owner'], 'owner', GroupAssetsBy.day, temporalScope: const TimelineTemporalScope.year(2026)),
    timeline.livePhotos(['owner'], 'owner', GroupAssetsBy.day),
    timeline.livePhotos(['owner'], 'owner', GroupAssetsBy.day, temporalScope: const TimelineTemporalScope.year(2026)),
  ];

  Future<void> expectPhotosEmpty() async {
    for (final source in photosQueries()) {
      expect(await source.assetSource(0, 100), isEmpty);
      expect(await source.bucketSource().first, isEmpty);
    }
  }

  Future<void> expectTrashVisible() async {
    final source = timeline.trash('owner', GroupAssetsBy.day);
    final assets = await source.assetSource(0, 100);
    expect(assets.map((asset) => asset.id), ['still']);
    expect((assets.single as RemoteAsset).deletedAt, deletedAt);
    expect((await source.bucketSource().first).single.assetCount, 1);
  }

  for (final v2 in [false, true]) {
    for (final external in [false, true]) {
      test('${v2 ? 'V2' : 'V1'} ${external ? 'external' : 'managed'} trash survives replay and reset', () async {
        final libraryId = external ? 'external-library' : null;
        await ctx.newLocalAsset(id: 'local-still', checksum: 'still-checksum', createdAt: createdAt);
        await (ctx.db.localAssetEntity.update()..where((row) => row.id.equals('local-still'))).write(
          const LocalAssetEntityCompanion(playbackStyle: Value(AssetPlaybackStyle.livePhoto)),
        );
        await ctx.newLocalAlbum(id: 'camera', backupSelection: BackupSelection.selected);
        await ctx.newLocalAlbumAsset(albumId: 'camera', assetId: 'local-still');

        await stream(payload(libraryId: libraryId), v2: v2);
        for (final source in photosQueries()) {
          final assets = await source.assetSource(0, 100);
          expect(assets.map((asset) => asset.id), ['still']);
          expect((assets.single as RemoteAsset).localId, 'local-still');
        }

        await stream(
          payload(libraryId: libraryId, trashDate: deletedAt),
          v2: v2,
        );
        await expectPhotosEmpty();
        await expectTrashVisible();

        // A later sync contains current server state: the retained trashed row
        // must continue suppressing its device checksum twin.
        await stream(
          payload(libraryId: libraryId, trashDate: deletedAt),
          v2: v2,
        );
        await sync.pruneAssets();
        await expectPhotosEmpty();
        await expectTrashVisible();

        // A delayed pre-Trash payload (including media mtime newer than the
        // capture date) is not a server restore. Both the server row and its
        // checksum-linked local twin must stay outside every Photos query.
        await stream(payload(libraryId: libraryId), v2: v2);
        await expectPhotosEmpty();
        await expectTrashVisible();

        await sync.reset();
        await ctx.newUser(id: 'owner');
        await ctx.newAuthUser(id: 'owner');
        // Reset must not erase identity while delayed pages arrive. The local
        // checksum twin is also suppressed before any remote row returns.
        await expectPhotosEmpty();
        await stream(payload(libraryId: libraryId), v2: v2);
        await expectPhotosEmpty();
        await expectTrashVisible();
        await stream(
          payload(libraryId: libraryId, trashDate: deletedAt),
          v2: v2,
        );
        await expectPhotosEmpty();
        await expectTrashVisible();

        // Only a verified current server restore, not an unversioned null
        // from a backfill/Space/album stream, reintroduces this identity.
        await sync.confirmRestore((await sync.getRestoreCandidates({'still': 'owner'})).single);
        await stream(payload(libraryId: libraryId), v2: v2);
        for (final source in photosQueries()) {
          expect((await source.assetSource(0, 100)).map((asset) => asset.id), ['still']);
          expect((await source.bucketSource().first).single.assetCount, 1);
        }
        expect(await timeline.trash('owner', GroupAssetsBy.day).assetSource(0, 100), isEmpty);
      });
    }
  }

  for (final userId in ['anna', 'docice', 'lenia']) {
    test('$userId managed/external photo/video trash stays out of paginated Photos', () async {
      await ctx.newUser(id: userId);
      for (final source in ['managed', 'external']) {
        for (final type in ['IMAGE', 'VIDEO']) {
          final id = '$userId-$source-$type';
          await stream({
            ...payload(trashDate: deletedAt),
            'id': id,
            'ownerId': userId,
            'checksum': '$id-checksum',
            'type': type,
            'libraryId': source == 'external' ? '$userId-library' : null,
            'livePhotoVideoId': null,
          }, v2: true);
        }
      }
      for (var index = 0; index < 3; index++) {
        await ctx.newRemoteAsset(
          id: '$userId-active-$index',
          ownerId: userId,
          createdAt: createdAt.add(Duration(minutes: index)),
        );
      }
      await ctx.newRemoteAsset(id: 'other-owner-active', ownerId: 'owner');
      final source = timeline.main([userId], userId, GroupAssetsBy.day);
      final first = await source.assetSource(0, 2);
      final second = await source.assetSource(2, 2);
      expect([...first, ...second].map((asset) => asset.id), [
        '$userId-active-2',
        '$userId-active-1',
        '$userId-active-0',
      ]);
      expect((await source.bucketSource().first).fold<int>(0, (count, bucket) => count + bucket.assetCount), 3);
      expect(await timeline.trash(userId, GroupAssetsBy.day).assetSource(0, 10), hasLength(4));
      expect(await timeline.trash('owner', GroupAssetsBy.day).assetSource(0, 10), isEmpty);
    });
  }

  test('server-only permanent-delete removes persisted row and paginated cache source', () async {
    await stream(payload(trashDate: deletedAt), v2: true);
    await expectTrashVisible();
    final deletion = api.SyncAssetDeleteV1.fromJson({'assetId': 'still'})!;
    await sync.deleteAssetsV1([deletion]);
    await sync.pruneAssets();
    expect(await RemoteAssetRepository(ctx.db).get('still'), isNull);
    await expectPhotosEmpty();
    expect(await timeline.trash('owner', GroupAssetsBy.day).assetSource(0, 10), isEmpty);
    // Device originals deliberately retained by a server-only delete remain
    // separate local sources; they are not cached copies of this server ID.
    await sync.deleteAssetsV1([deletion]);
    await expectPhotosEmpty();
  });

  test('offline restart reopens persisted Trash state before reconnect sync', () async {
    final directory = await Directory.systemTemp.createTemp('gallery-trash-test-');
    final file = File('${directory.path}/cache.sqlite');
    var cache = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    addTearDown(() async {
      await cache.close();
      await directory.delete(recursive: true);
    });
    final user = await ctx.db.select(ctx.db.userEntity).getSingle();
    await cache.into(cache.userEntity).insert(user);
    final dto = api.SyncAssetV2.fromJson(payload(trashDate: deletedAt))!;
    await SyncStreamRepository(cache).updateAssetsV2([dto]);
    await cache.close();
    cache = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    final reopened = TimelineRepository(cache);
    expect(await reopened.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 10), isEmpty);
    expect((await reopened.trash('owner', GroupAssetsBy.day).assetSource(0, 10)).map((asset) => asset.id), ['still']);
    await SyncStreamRepository(cache).updateAssetsV2([dto]);
    expect(await reopened.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 10), isEmpty);
    // Reconnect may replay an older page after restart; persistence is the
    // guard, not a process-local/widget hide set.
    await SyncStreamRepository(cache).updateAssetsV2([api.SyncAssetV2.fromJson(payload())!]);
    expect(await reopened.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 10), isEmpty);
    expect((await reopened.trash('owner', GroupAssetsBy.day).assetSource(0, 10)).map((asset) => asset.id), ['still']);
  });

  test('trashed Live still retains hidden paired motion without a standalone tile', () async {
    await ctx.newRemoteAsset(id: 'motion', ownerId: 'owner', type: AssetType.video, visibility: AssetVisibility.hidden);
    await stream(payload(trashDate: deletedAt), v2: true);
    await expectPhotosEmpty();
    final still = (await RemoteAssetRepository(ctx.db).get('still'))!;
    final motion = (await RemoteAssetRepository(ctx.db).get('motion'))!;
    expect(still.livePhotoVideoId, motion.id);
    expect(motion.visibility, AssetVisibility.hidden);
    await sync.confirmRestore((await sync.getRestoreCandidates({'still': 'owner'})).single);
    await stream(payload(), v2: true);
    expect((await timeline.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 10)).map((asset) => asset.id), [
      'still',
    ]);
  });

  test('restore confirmation cannot clear a newer Trash tombstone or another owner', () async {
    await stream(payload(trashDate: deletedAt), v2: true);
    expect(await sync.getRestoreCandidates({'still': 'another-owner'}), isEmpty);
    final checked = (await sync.getRestoreCandidates({'still': 'owner'})).single;
    final newerTrash = deletedAt.add(const Duration(seconds: 5));
    await sync.updateAssetsV2([api.SyncAssetV2.fromJson(payload(trashDate: newerTrash))!]);
    await sync.confirmRestore(checked);
    await sync.updateAssetsV2([api.SyncAssetV2.fromJson(payload())!]);
    await expectPhotosEmpty();
    expect((await RemoteAssetRepository(ctx.db).get('still'))!.deletedAt, newerTrash);
  });

  test('same SQLite second restore-retrash invalidates the prior confirmation', () async {
    await stream(payload(trashDate: deletedAt), v2: true);
    final checked = (await sync.getRestoreCandidates({'still': 'owner'})).single;
    final remote = RemoteAssetRepository(ctx.db);
    await remote.restoreTrash(['still']);
    await remote.trash(['still']);
    // Pin the second-precision DB timestamp to the old value. The actions
    // still use the real repository; this deterministically constructs the
    // ABA collision without timing/sleeps or assuming a sufficiently fast CPU.
    await (ctx.db.remoteAssetEntity.update()..where((row) => row.id.equals('still'))).write(
      RemoteAssetEntityCompanion(deletedAt: Value(checked.deletedAt)),
    );
    await sync.confirmRestore(checked);
    await stream(payload(), v2: true);
    await expectPhotosEmpty();
    expect((await remote.get('still'))!.isTrashed, isTrue);
  });

  test('reset Trash metadata is scoped by endpoint and owner, and logout removes it', () async {
    await stream(payload(trashDate: deletedAt), v2: true);
    await sync.reset();
    expect(await sync.getRestoreCandidates({'still': 'other-owner'}), isEmpty);
    expect(await sync.getRestoreCandidates({'still': 'owner'}), hasLength(1));
    final previousServer = (await sync.getRestoreCandidates({'still': 'owner'})).single;
    await StoreRepository(ctx.db).upsert(StoreKey.serverEndpoint, 'https://other-gallery.invalid/api');
    expect(await sync.getRestoreCandidates({'still': 'owner'}), isEmpty);
    await sync.confirmRestore(previousServer);
    await StoreRepository(ctx.db).upsert(StoreKey.serverEndpoint, 'https://gallery.invalid/api');
    expect(await sync.getRestoreCandidates({'still': 'owner'}), hasLength(1));
    await StoreRepository(ctx.db).upsert(StoreKey.serverEndpoint, 'https://other-gallery.invalid/api');
    await ctx.newUser(id: 'owner');
    await stream(payload(), v2: true);
    expect((await RemoteAssetRepository(ctx.db).get('still'))!.isTrashed, isFalse);
    await sync.reset(retainTrash: false);
    final retained = await (ctx.db.settingsEntity.select()..where((row) => row.key.like('sync.trash-reset.%'))).get();
    expect(retained, isEmpty);
    expect(await ctx.db.remoteAssetEntity.select().get(), isEmpty);
  });

  test('new confirmed Trash during reset invalidates an in-flight restore snapshot', () async {
    await stream(payload(trashDate: deletedAt), v2: true);
    await sync.reset();
    final checked = (await sync.getRestoreCandidates({'still': 'owner'})).single;
    // The cached UI can still complete a server Trash operation while reset
    // has removed the row; keep its newer tombstone in the retained metadata.
    await RemoteAssetRepository(ctx.db).trash(['still']);
    await sync.confirmRestore(checked);
    expect(await sync.getRestoreCandidates({'still': 'owner'}), hasLength(1));
    await ctx.newUser(id: 'owner');
    await stream(payload(), v2: true);
    await expectPhotosEmpty();
    expect((await RemoteAssetRepository(ctx.db).get('still'))!.isTrashed, isTrue);
  });

  test('explicit Restore All and permanent server Delete clear only their retained identities', () async {
    await ctx.newUser(id: 'other');
    await stream(payload(trashDate: deletedAt), v2: true);
    await ctx.newRemoteAsset(id: 'other-trash', ownerId: 'other', deletedAt: deletedAt);
    await sync.reset();
    final remote = RemoteAssetRepository(ctx.db);
    final snapshots = await remote.beginRestoreAllTrash('owner');
    // Restore is optimistic. Its retained identity remains until the server
    // accepts the request, then the other owner's marker remains untouched.
    expect(await sync.getRestoreCandidates({'still': 'owner'}), isEmpty);
    await remote.completeTrashOperation(snapshots, success: true);
    expect(await sync.getRestoreCandidates({'still': 'owner'}), isEmpty);
    expect(await sync.getRestoreCandidates({'other-trash': 'other'}), hasLength(1));
    await sync.deleteAssetsV1([api.SyncAssetDeleteV1(assetId: 'other-trash')]);
    expect(await sync.getRestoreCandidates({'other-trash': 'other'}), isEmpty);
    await ctx.newUser(id: 'owner');
    await stream(payload(), v2: true);
    expect((await RemoteAssetRepository(ctx.db).get('still'))!.isTrashed, isFalse);
  });

  test('failed bulk restore after reset preserves the deletion date and blocks stale active replay', () async {
    await stream(payload(trashDate: deletedAt), v2: true);
    await sync.reset();
    final remote = RemoteAssetRepository(ctx.db);

    final snapshots = await remote.beginRestoreAllTrash('owner');
    expect(await remote.get('still'), isNull);
    expect(await sync.getRestoreCandidates({'still': 'owner'}), isEmpty);

    await remote.completeTrashOperation(snapshots, success: false, definiteFailure: true);
    await ctx.newUser(id: 'owner');
    await stream(payload(), v2: true);

    await expectPhotosEmpty();
    await expectTrashVisible();
    expect((await remote.get('still'))!.deletedAt, deletedAt);
  });

  test('optimistic single restore keeps its retained date through stale active sync', () async {
    await stream(payload(trashDate: deletedAt), v2: true);
    final remote = RemoteAssetRepository(ctx.db);

    await remote.restoreTrash(['still']);
    expect((await remote.get('still'))!.isTrashed, isFalse);
    expect(await sync.getRestoreCandidates({'still': 'owner'}), hasLength(1));

    await stream(payload(), v2: true);
    await expectPhotosEmpty();
    await expectTrashVisible();
    expect((await remote.get('still'))!.deletedAt, deletedAt);
  });

  test('authoritative restore clears the retained tombstone after optimistic local restore', () async {
    await stream(payload(trashDate: deletedAt), v2: true);
    final remote = RemoteAssetRepository(ctx.db);

    await remote.restoreTrash(['still']);
    final candidate = (await sync.getRestoreCandidates({'still': 'owner'})).single;
    expect((await remote.get('still'))!.isTrashed, isFalse);

    await sync.confirmRestore(candidate);
    expect(await sync.getRestoreCandidates({'still': 'owner'}), isEmpty);

    await stream(payload(), v2: true);
    expect((await timeline.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 10)).map((a) => a.id), ['still']);
  });

  test('reset metadata survives SQLite reopen without recreating inaccessible asset rows', () async {
    final directory = await Directory.systemTemp.createTemp('gallery-trash-reset-test-');
    final file = File('${directory.path}/cache.sqlite');
    var cache = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    addTearDown(() async {
      await cache.close();
      await directory.delete(recursive: true);
    });
    await StoreRepository(cache).upsert(StoreKey.serverEndpoint, 'https://gallery.invalid/api');
    await cache.into(cache.userEntity).insert(await ctx.db.select(ctx.db.userEntity).getSingle());
    await SyncStreamRepository(cache).updateAssetsV2([api.SyncAssetV2.fromJson(payload(trashDate: deletedAt))!]);
    await SyncStreamRepository(cache).reset();
    await cache.close();
    cache = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    final reloaded = SyncStreamRepository(cache);
    expect(await cache.remoteAssetEntity.select().get(), isEmpty);
    expect(await cache.userEntity.select().get(), isEmpty);
    final checked = (await reloaded.getRestoreCandidates({'still': 'owner'})).single;
    await cache.into(cache.userEntity).insert(await ctx.db.select(ctx.db.userEntity).getSingle());
    await reloaded.updateAssetsV2([api.SyncAssetV2.fromJson(payload())!]);
    final photos = TimelineRepository(cache).main(['owner'], 'owner', GroupAssetsBy.day);
    expect(await photos.assetSource(0, 10), isEmpty);
    await reloaded.confirmRestore(checked);
    await reloaded.updateAssetsV2([api.SyncAssetV2.fromJson(payload())!]);
    expect((await photos.assetSource(0, 10)).map((asset) => asset.id), ['still']);
  });

  test('upload placeholder cannot bypass retained Trash during reset', () async {
    await stream(payload(trashDate: deletedAt), v2: true);
    await sync.reset();
    await ctx.newUser(id: 'owner');
    await RemoteAlbumRepository(ctx.db).upsertRemoteAssetStub(
      remoteId: 'still',
      ownerId: 'owner',
      source: LocalAsset(
        id: 'local-still',
        name: 'IMG_1000.JPG',
        checksum: 'still-checksum',
        type: AssetType.image,
        playbackStyle: AssetPlaybackStyle.livePhoto,
        isEdited: false,
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
    await expectPhotosEmpty();
    expect((await RemoteAssetRepository(ctx.db).get('still'))!.isTrashed, isTrue);
  });

  test('successful explicit single/all Restore remains eligible and is owner-scoped', () async {
    final remote = RemoteAssetRepository(ctx.db);
    await stream(payload(trashDate: deletedAt), v2: true);
    await ctx.newUser(id: 'other');
    await ctx.newRemoteAsset(id: 'other-trash', ownerId: 'other', deletedAt: deletedAt);
    final single = await remote.beginTrashOperation(['still'], restore: true);
    await remote.completeTrashOperation(single, success: true);
    await stream(payload(), v2: true);
    expect((await timeline.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 10)).map((asset) => asset.id), [
      'still',
    ]);
    await remote.trash(['still']);
    final all = await remote.beginRestoreAllTrash('owner');
    await remote.completeTrashOperation(all, success: true);
    expect((await timeline.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 10)).map((asset) => asset.id), [
      'still',
    ]);
    expect((await remote.get('other-trash'))!.isTrashed, isTrue);
  });

  test('V2 nullable dimensions and duration survive temporal Photos reads', () async {
    await stream({...payload(), 'width': null, 'height': null}, v2: true);
    final source = timeline.main(
      ['owner'],
      'owner',
      GroupAssetsBy.day,
      temporalScope: const TimelineTemporalScope.year(2026),
    );
    final asset = (await source.assetSource(0, 100)).single;
    expect(asset.id, 'still');
    expect(asset.width, isNull);
    expect(asset.height, isNull);
    expect(asset.durationMs, isNull);
    expect((await source.bucketSource().first).single.assetCount, 1);
  });

  test('stack children exclude trash while preserving the primary visibility context', () async {
    final remote = RemoteAssetRepository(ctx.db);
    await ctx.newRemoteAsset(id: 'primary', ownerId: 'owner', stackId: 'stack', visibility: AssetVisibility.archive);
    await ctx.newRemoteAsset(
      id: 'active-child',
      ownerId: 'owner',
      stackId: 'stack',
      visibility: AssetVisibility.archive,
    );
    await ctx.newRemoteAsset(id: 'trashed-child', ownerId: 'owner', stackId: 'stack', deletedAt: deletedAt);
    final primary = (await remote.get('primary'))!;

    expect((await remote.getStackChildren(primary)).map((asset) => asset.id), ['active-child']);
    expect((await remote.get('trashed-child'))!.deletedAt, deletedAt);
  });
}
