import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/app/settings.drift.dart';
import 'package:immich_mobile/data/db/main/table/app/store.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/album.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/pending_local_trash.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late TrashedLocalAssetRepository sut;
  late LocalAsset asset;
  final now = DateTime.utc(2026, 10, 24, 12);
  final revision = DateTime.utc(2026, 10, 20, 10);

  Future<LocalAsset> seedAsset({String id = 'local-1', String remoteId = 'remote-1', String? ownerId}) async {
    final row = await ctx.newLocalAsset(
      id: id,
      name: '$id.jpg',
      checksum: 'checksum-$id',
      createdAt: revision,
      updatedAt: revision,
      width: 4000,
      height: 3000,
      orientation: 0,
    );
    await ctx.newLocalAlbumAsset(albumId: 'camera', assetId: id);
    await ctx.newRemoteAsset(
      id: remoteId,
      checksum: 'checksum-$id',
      ownerId: ownerId ?? 'owner',
      createdAt: revision,
      deletedAt: now,
    );
    return row.toDto();
  }

  Future<List<PendingLocalTrash>> pending({Drift? database}) async {
    final db = database ?? ctx.db;
    final rows = await (db.settingsEntity.select()..where((row) => row.key.like('local-trash.v1.%'))).get();
    return rows.map((row) => PendingLocalTrash.fromStored(row.key, row.value!)).toList();
  }

  Future<void> enqueue({bool permanent = false}) => sut.enqueueTrash(
    {
      'camera': [asset],
    },
    permanent: permanent,
    remoteIds: ['remote-1'],
  );

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = TrashedLocalAssetRepository(ctx.db);
    await ctx.newUser(id: 'owner');
    await ctx.newAuthUser(id: 'owner');
    await ctx.newLocalAlbum(id: 'camera', backupSelection: BackupSelection.selected);
    asset = await seedAsset();
  });

  tearDown(() async => ctx.dispose());

  test('enqueue persists an intent without claiming Android has moved the original', () async {
    await enqueue();

    final intent = (await pending()).single;
    expect(intent.asset.id, asset.id);
    expect(intent.asset.checksum, asset.checksum);
    expect(intent.albumIds, ['camera']);
    expect(intent.remoteReasons, {'remote-1': false});
    expect(intent.attempts, 0);
    expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
    expect((await ctx.db.localAssetEntity.select().getSingle()).id, asset.id);
  });

  test('pending intents survive a fresh SQLite connection after application restart', () async {
    await enqueue();
    final claimed = (await sut.claimPendingTrash(now: now)).single;
    await sut.failPendingTrash(claimed, 'permissionDenied', 'MANAGE_MEDIA was revoked', now: now);
    final before = (await pending()).single;
    final directory = await Directory.systemTemp.createTemp('foto-pending-trash-test-');
    final file = File('${directory.path}/mobile.sqlite');
    Drift? reopened;
    try {
      await ctx.db.customStatement('VACUUM INTO ?', [file.path]);
      reopened = Drift(NativeDatabase(file));
      final recovered = (await pending(database: reopened)).single;
      expect(recovered.rawValue, before.rawValue);
      expect(recovered.code, 'permissionDenied');
      final freshRepository = TrashedLocalAssetRepository(reopened);
      expect(await freshRepository.claimPendingTrash(now: now), isEmpty);
      final retried = await freshRepository.claimPendingTrash(now: now.add(const Duration(hours: 1)));
      expect(retried.single.asset.id, asset.id);
      expect(retried.single.attempts, 2);
    } finally {
      await reopened?.close();
      await directory.delete(recursive: true);
    }
  });

  test('replayed server events do not reset failure backoff or duplicate an intent', () async {
    await enqueue();
    final claimed = (await sut.claimPendingTrash(now: now)).single;
    await sut.failPendingTrash(claimed, 'providerError', 'deleteWithIds failed', now: now);
    final failed = (await pending()).single;

    await enqueue();
    await enqueue();

    final replayed = (await pending()).single;
    expect(replayed.attempts, failed.attempts);
    expect(replayed.nextAttemptAt, failed.nextAttemptAt);
    expect(replayed.code, 'providerError');
    expect(await sut.claimPendingTrash(now: now.add(const Duration(seconds: 59))), isEmpty);
  });

  test('a claimed intent cannot be claimed again until its durable lease expires', () async {
    await enqueue();
    final first = (await sut.claimPendingTrash(now: now)).single;

    expect(await sut.claimPendingTrash(now: now), isEmpty);
    expect(await sut.claimPendingTrash(now: now.add(const Duration(seconds: 119))), isEmpty);

    final second = (await sut.claimPendingTrash(now: now.add(const Duration(minutes: 3)))).single;
    expect(second.attempts, first.attempts + 1);
    expect(second.rawValue, isNot(first.rawValue));
  });

  test('only verified completion atomically moves the DB asset and removes its intent', () async {
    await enqueue();
    final claimed = (await sut.claimPendingTrash(now: now)).single;
    await sut.failPendingTrash(claimed, 'providerError', 'Move failed', now: now);

    expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
    expect(await ctx.db.localAssetEntity.select().get(), hasLength(1));
    final retry = (await sut.claimPendingTrash(now: now.add(const Duration(hours: 1)))).single;
    await sut.completePendingTrash(retry);

    expect(await pending(), isEmpty);
    expect(await ctx.db.localAssetEntity.select().get(), isEmpty);
    final trashed = await ctx.db.trashedLocalAssetEntity.select().getSingle();
    expect(trashed.id, asset.id);
    expect(trashed.albumId, 'camera');
    expect(trashed.checksum, asset.checksum);
    await enqueue();
    expect(await pending(), isEmpty);
  });

  test('completion from an expired worker cannot erase a newer claim', () async {
    await enqueue();
    final stale = (await sut.claimPendingTrash(now: now)).single;
    final current = (await sut.claimPendingTrash(now: now.add(const Duration(minutes: 3)))).single;

    await sut.completePendingTrash(stale);
    await sut.failPendingTrash(stale, 'providerError', 'late result', now: now);

    expect((await pending()).single.rawValue, current.rawValue);
    expect(await ctx.db.localAssetEntity.select().get(), hasLength(1));
    expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
    await sut.completePendingTrash(current);
    expect(await pending(), isEmpty);
  });

  test('a DB write failure rolls back completion and preserves its durable intent', () async {
    await enqueue();
    final claimed = (await sut.claimPendingTrash(now: now)).single;
    await ctx.db.customStatement('''
      CREATE TEMP TRIGGER reject_test_trash_insert
      BEFORE INSERT ON trashed_local_asset_entity
      BEGIN SELECT RAISE(ABORT, 'injected trash persistence failure'); END
    ''');

    await expectLater(sut.completePendingTrash(claimed), throwsA(anything));

    expect((await pending()).single.rawValue, claimed.rawValue);
    expect(await ctx.db.localAssetEntity.select().get(), hasLength(1));
    expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
    await ctx.db.customStatement('DROP TRIGGER reject_test_trash_insert');
    await sut.completePendingTrash(claimed);
    expect(await pending(), isEmpty);
  });

  test('retry backoff increases and remains bounded without an active retry loop', () async {
    await enqueue();
    var instant = now;
    var previousDelay = Duration.zero;
    for (var attempt = 0; attempt < 12; attempt++) {
      final claimed = (await sut.claimPendingTrash(now: instant)).single;
      await sut.failPendingTrash(claimed, 'providerError', 'Provider unavailable', now: instant);
      final failed = (await pending()).single;
      final delay = failed.nextAttemptAt.difference(instant);
      expect(delay, greaterThanOrEqualTo(previousDelay));
      expect(delay, lessThanOrEqualTo(const Duration(hours: 6)));
      expect(await sut.claimPendingTrash(now: instant), isEmpty);
      instant = failed.nextAttemptAt;
      previousDelay = delay;
    }
    expect(previousDelay, const Duration(hours: 6));
    expect((await pending()).single.attempts, 12);
  });

  test('permanent server deletion retains its Android trash intent after remote row removal', () async {
    await enqueue(permanent: true);
    await (ctx.db.delete(ctx.db.remoteAssetEntity)..where((row) => row.id.equals('remote-1'))).go();

    final claimed = (await sut.claimPendingTrash(now: now)).single;

    expect(claimed.remoteReasons, {'remote-1': true});
    expect(claimed.asset.checksum, asset.checksum);
    expect(await ctx.db.localAssetEntity.select().get(), hasLength(1));
    expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
  });

  test('a temporary remote backfill gap defers work without losing the trash intent', () async {
    await enqueue();
    await (ctx.db.delete(ctx.db.remoteAssetEntity)..where((row) => row.id.equals('remote-1'))).go();

    expect(await sut.claimPendingTrash(now: now), isEmpty);
    final deferred = (await pending()).single;
    expect(deferred.code, 'remoteStateUnknown');
    expect(deferred.attempts, 0);
    expect(await ctx.db.localAssetEntity.select().get(), hasLength(1));
    await ctx.newRemoteAsset(id: 'remote-1', checksum: asset.checksum, ownerId: 'owner', deletedAt: now);
    expect((await sut.claimPendingTrash(now: now.add(const Duration(minutes: 2)))).single.asset.id, asset.id);
  });

  test('refreshing the actual OS trash snapshot cannot erase uncompleted work', () async {
    await enqueue();
    final claimed = (await sut.claimPendingTrash(now: now)).single;
    await sut.failPendingTrash(claimed, 'providerError', 'Android refused trash', now: now);
    final before = (await pending()).single;

    await sut.processTrashSnapshot([]);

    expect((await pending()).single.rawValue, before.rawValue);
    expect(await ctx.db.localAssetEntity.select().get(), hasLength(1));
    expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
  });

  test('Restore cancels an uncompleted trash intent without restoring or deleting media', () async {
    await enqueue();
    await (ctx.db.update(
      ctx.db.remoteAssetEntity,
    )..where((row) => row.id.equals('remote-1'))).write(const RemoteAssetEntityCompanion(deletedAt: Value(null)));
    await sut.cancelPendingTrash(['remote-1']);

    expect(await pending(), isEmpty);
    expect(await sut.claimPendingTrash(now: now), isEmpty);
    expect((await ctx.db.localAssetEntity.select().getSingle()).id, asset.id);
    expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
  });

  test('an unconfirmed active event cannot cancel retained server trash', () async {
    await enqueue();

    // Build 17 intentionally retains deletedAt until a canonical Restore is
    // confirmed, even if an incoming index event superficially looks active.
    await sut.cancelPendingTrash(['remote-1']);

    expect(await pending(), hasLength(1));
    expect((await sut.claimPendingTrash(now: now)).single.asset.id, asset.id);
    expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
  });

  test('an index visibility tombstone never authorizes Android trash', () async {
    await (ctx.db.update(ctx.db.remoteAssetEntity)..where((row) => row.id.equals('remote-1'))).write(
      const RemoteAssetEntityCompanion(isIndexTombstone: Value(true)),
    );
    await enqueue();

    expect(await pending(), isEmpty);
    expect(await sut.claimPendingTrash(now: now), isEmpty);
    expect(await ctx.db.localAssetEntity.select().get(), hasLength(1));
  });

  test('a later index tombstone cannot turn an existing intent into a native action', () async {
    await enqueue();
    await (ctx.db.update(ctx.db.remoteAssetEntity)..where((row) => row.id.equals('remote-1'))).write(
      const RemoteAssetEntityCompanion(isIndexTombstone: Value(true)),
    );

    expect(await sut.claimPendingTrash(now: now), isEmpty);
    expect(await pending(), isEmpty);
    expect(await ctx.db.localAssetEntity.select().get(), hasLength(1));
  });

  test('terminal events promote a pending intent after its local row disappeared', () async {
    await enqueue();
    await (ctx.db.delete(ctx.db.localAlbumAssetEntity)..where((row) => row.assetId.equals(asset.id))).go();
    await (ctx.db.delete(ctx.db.localAssetEntity)..where((row) => row.id.equals(asset.id))).go();

    await sut.enqueueTrash({}, permanent: true, remoteIds: ['remote-1']);
    await (ctx.db.delete(ctx.db.remoteAssetEntity)..where((row) => row.id.equals('remote-1'))).go();

    final claimed = (await sut.claimPendingTrash(now: now)).single;
    expect(claimed.remoteReasons, {'remote-1': true});
    expect(claimed.asset.checksum, asset.checksum);
    expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
  });

  test('malformed and future-version intents remain durable without blocking valid work', () async {
    await enqueue();
    final valid = (await pending()).single;
    final malformedKey = '${valid.key}-malformed';
    final futureKey = '${valid.key}-future';
    const malformed = '{not-json';
    final future = jsonEncode({...valid.toJson(), 'version': 2});
    await ctx.db
        .into(ctx.db.settingsEntity)
        .insert(SettingsEntityCompanion.insert(key: malformedKey, value: const Value(malformed)));
    await ctx.db
        .into(ctx.db.settingsEntity)
        .insert(SettingsEntityCompanion.insert(key: futureKey, value: Value(future)));

    final claimed = await sut.claimPendingTrash(now: now);

    expect(claimed.map((item) => item.asset.id), [asset.id]);
    final retained = await (ctx.db.settingsEntity.select()..where((row) => row.key.isIn([malformedKey, futureKey])))
        .get();
    expect({for (final row in retained) row.key: row.value}, {malformedKey: malformed, futureKey: future});
    await sut.retryPermissionBlockedTrash(now: now);
    await sut.cancelPendingTrash(['remote-1']);
    expect(
      await (ctx.db.settingsEntity.select()..where((row) => row.key.isIn([malformedKey, futureKey]))).get(),
      hasLength(2),
    );
  });

  test('a restored remote row cancels the corresponding nonpermanent intent at claim', () async {
    await enqueue();
    await (ctx.db.update(
      ctx.db.remoteAssetEntity,
    )..where((row) => row.id.equals('remote-1'))).write(const RemoteAssetEntityCompanion(deletedAt: Value(null)));

    expect(await sut.claimPendingTrash(now: now), isEmpty);
    expect(await pending(), isEmpty);
    expect(await ctx.db.localAssetEntity.select().get(), hasLength(1));
  });

  test('a changed or reused local id cannot be trashed using an old queued revision', () async {
    await enqueue();
    await (ctx.db.update(ctx.db.localAssetEntity)..where((row) => row.id.equals(asset.id))).write(
      LocalAssetEntityCompanion(
        checksum: const Value('new-original-checksum'),
        updatedAt: Value(revision.add(const Duration(seconds: 1))),
      ),
    );

    expect(await sut.claimPendingTrash(now: now), isEmpty);
    expect(await pending(), isEmpty);
    expect((await ctx.db.localAssetEntity.select().getSingle()).checksum, 'new-original-checksum');
  });

  test('deselecting its backup album cancels pending trash without touching the local asset', () async {
    await enqueue();
    await (ctx.db.update(ctx.db.localAlbumEntity)..where((row) => row.id.equals('camera'))).write(
      const LocalAlbumEntityCompanion(backupSelection: Value(BackupSelection.none)),
    );

    expect(await sut.claimPendingTrash(now: now), isEmpty);
    expect(await pending(), isEmpty);
    expect(await ctx.db.localAssetEntity.select().get(), hasLength(1));
    expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
  });

  test('moving a file outside selected backup albums cancels its old intent', () async {
    await enqueue();
    await (ctx.db.delete(ctx.db.localAlbumAssetEntity)..where((row) => row.assetId.equals(asset.id))).go();
    await ctx.newLocalAlbum(id: 'unselected', backupSelection: BackupSelection.none);
    await ctx.newLocalAlbumAsset(albumId: 'unselected', assetId: asset.id);

    expect(await sut.claimPendingTrash(now: now), isEmpty);
    expect(await pending(), isEmpty);
    expect(await ctx.db.localAssetEntity.select().get(), hasLength(1));
  });

  test('a file moved into another selected album uses its current album on completion', () async {
    await enqueue();
    await (ctx.db.delete(ctx.db.localAlbumAssetEntity)..where((row) => row.assetId.equals(asset.id))).go();
    await ctx.newLocalAlbum(id: 'new-camera', backupSelection: BackupSelection.selected);
    await ctx.newLocalAlbumAsset(albumId: 'new-camera', assetId: asset.id);

    final claimed = (await sut.claimPendingTrash(now: now)).single;
    expect(claimed.albumIds, ['new-camera']);
    await sut.completePendingTrash(claimed);

    expect((await ctx.db.trashedLocalAssetEntity.select().getSingle()).albumId, 'new-camera');
    expect(await pending(), isEmpty);
  });

  test('permission restoration expedites only permission-blocked retries', () async {
    final other = await seedAsset(id: 'local-2', remoteId: 'remote-2');
    await sut.enqueueTrash({
      'camera': [asset, other],
    });
    final claimed = await sut.claimPendingTrash(now: now);
    final byId = {for (final intent in claimed) intent.asset.id: intent};
    await sut.failPendingTrash(byId[asset.id]!, 'permissionDenied', 'No permission', now: now);
    await sut.failPendingTrash(byId[other.id]!, 'providerError', 'Provider unavailable', now: now);
    await sut.updateManageMediaPermission(false);
    expect(await sut.updateManageMediaPermission(true), isTrue);
    await sut.retryPermissionBlockedTrash(now: now.add(const Duration(seconds: 10)));

    final retried = await sut.claimPendingTrash(now: now.add(const Duration(seconds: 10)));

    expect(retried.map((item) => item.asset.id), [asset.id]);
    expect((await pending()).singleWhere((item) => item.asset.id == other.id).code, 'providerError');
  });

  test('another account cannot claim the previous account trash intents', () async {
    await enqueue();
    await ctx.db.delete(ctx.db.authUserEntity).go();
    await ctx.newUser(id: 'other-owner');
    await ctx.newAuthUser(id: 'other-owner');

    expect(await sut.claimPendingTrash(now: now), isEmpty);
    expect(await pending(), hasLength(1));
    await ctx.db.delete(ctx.db.authUserEntity).go();
    await ctx.newAuthUser(id: 'owner');
    expect((await sut.claimPendingTrash(now: now)).single.asset.id, asset.id);
  });

  test('changing server endpoint does not execute intents from the previous server', () async {
    await enqueue();
    await ctx.db
        .into(ctx.db.storeEntity)
        .insertOnConflictUpdate(
          StoreEntityCompanion(
            id: Value(StoreKey.serverEndpoint.id),
            stringValue: const Value('https://other.invalid'),
          ),
        );

    expect(await sut.claimPendingTrash(now: now), isEmpty);
    expect(await pending(), hasLength(1));
    await (ctx.db.delete(ctx.db.storeEntity)..where((row) => row.id.equals(StoreKey.serverEndpoint.id))).go();
    expect((await sut.claimPendingTrash(now: now)).single.asset.id, asset.id);
  });

  test('a partner trash event cannot enqueue deletion of the owner device original', () async {
    await ctx.newUser(id: 'partner');
    final partnerAsset = await seedAsset(id: 'local-partner', remoteId: 'remote-partner', ownerId: 'partner');

    await sut.enqueueTrash(
      {
        'camera': [partnerAsset],
      },
      remoteIds: ['remote-partner'],
    );

    expect(await pending(), isEmpty);
    expect(await sut.claimPendingTrash(now: now), isEmpty);
    expect(await ctx.db.localAssetEntity.select().get(), hasLength(2));
  });
}
