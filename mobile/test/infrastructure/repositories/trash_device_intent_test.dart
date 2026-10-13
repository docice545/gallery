import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../medium/repository_context.dart';
import '../../repository.mocks.dart';

void main() {
  late MediumRepositoryContext context;
  late SyncStreamRepository sync;
  late RemoteAssetRepository remote;
  late TrashedLocalAssetRepository deviceTrash;

  setUp(() async {
    context = MediumRepositoryContext();
    await context.newUser(id: 'owner');
    await context.newAuthUser(id: 'owner');
    sync = SyncStreamRepository(context.db);
    remote = RemoteAssetRepository(context.db);
    deviceTrash = TrashedLocalAssetRepository(context.db);
    await context.newRemoteAsset(id: 'remote', ownerId: 'owner', checksum: 'checksum');
    await context.newLocalAsset(id: 'local', checksum: 'checksum');
    await context.newLocalAlbum(id: 'album', backupSelection: BackupSelection.selected);
    await context.newLocalAlbumAsset(albumId: 'album', assetId: 'local');
  });

  tearDown(() => context.dispose());

  test('Gallery-only Trash remains server-only during a later local rescan', () async {
    await remote.beginTrashOperation(['remote'], restore: false);
    expect(await deviceTrash.getToTrash(), isEmpty);
  });

  test(
    'completed receipt before Trash sync survives OS denial and a database restart with its original identity',
    () async {
      // This cache has only the active page; the server's completed receipt is
      // authoritative even if the earlier Trash event never reached this phone.
      expect((await remote.get('remote'))!.isTrashed, isFalse);
      await sync.retainPermanentDeletion(['remote']);
      final media = MockAssetMediaRepository();
      when(() => media.deleteAll(['local'], trash: false)).thenAnswer((_) async => []);
      final localIds = await sync.getDeletionLocalIds(['remote']);
      expect(localIds, ['local']);
      final outcome = await CleanupService(
        context.db.localAssetRepository,
        media,
        trashedLocalRepository: deviceTrash,
      ).deleteLocalAssetsDetailed(localIds, trash: false);
      expect(outcome.deletedIds, isEmpty);
      expect(outcome.remainingIds, ['local']);
      await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('remote'));

      final directory = await Directory.systemTemp.createTemp('gallery-device-receipt-restart-');
      final file = File('${directory.path}/cache.sqlite');
      var cache = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
      addTearDown(() async {
        await cache.close();
        await directory.delete(recursive: true);
      });
      for (final row in await context.db.userEntity.select().get()) {
        await cache.into(cache.userEntity).insert(row);
      }
      for (final row in await context.db.authUserEntity.select().get()) {
        await cache.into(cache.authUserEntity).insert(row);
      }
      for (final row in await context.db.localAssetEntity.select().get()) {
        await cache.into(cache.localAssetEntity).insert(row);
      }
      for (final row in await context.db.settingsEntity.select().get()) {
        await cache.into(cache.settingsEntity).insert(row);
      }
      for (final row in await context.db.storeEntity.select().get()) {
        await cache.into(cache.storeEntity).insert(row);
      }
      await cache.close();
      cache = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
      final restarted = SyncStreamRepository(cache);
      expect(await restarted.getPendingDeviceDeletionAssetIds('owner'), ['remote']);
      expect(await restarted.getDeletionLocalIds(['remote']), ['local']);
      final state = jsonDecode((await cache.settingsEntity.select().getSingle()).value!) as Map<String, dynamic>;
      expect(state['ownerId'], 'owner');
      expect(state['checksum'], 'checksum');
      expect(state['permanent'], isTrue);
      expect(state['permanentComplete'], isTrue);
    },
  );

  test('completed receipt retains an existing Trash timestamp and cannot authorize another owner', () async {
    final date = DateTime.utc(2025, 7, 6);
    await (context.db.remoteAssetEntity.update()..where((row) => row.id.equals('remote'))).write(
      RemoteAssetEntityCompanion(deletedAt: Value(date)),
    );
    await sync.retainPermanentDeletion(['remote']);
    final state = jsonDecode((await context.db.settingsEntity.select().getSingle()).value!) as Map<String, dynamic>;
    expect(state['deletedAt'], date.millisecondsSinceEpoch);
    expect(await sync.getPendingDeviceDeletionAssetIds('other-owner'), isEmpty);
    await context.db.authUserEntity.deleteWhere((row) => row.id.equals('owner'));
    expect(await sync.getPendingDeviceDeletionAssetIds('owner'), isEmpty);
    expect(await sync.getDeletionLocalIds(['remote']), isEmpty);
  });

  test(
    'ordinary retained Trash preservation never adopts active or offline-index rows without a completed receipt',
    () async {
      expect(await sync.updateRetainedTrash(['remote'], DateTime.utc(2026), preserveExistingDates: true), isEmpty);
      expect(await context.db.settingsEntity.select().get(), isEmpty);
      await (context.db.remoteAssetEntity.update()..where((row) => row.id.equals('remote'))).write(
        RemoteAssetEntityCompanion(deletedAt: Value(DateTime.utc(2026)), isIndexTombstone: const Value(true)),
      );
      expect(await sync.getPendingDeviceDeletionAssetIds('owner'), isEmpty);
      expect(await sync.getDeviceTrashSyncIds(['remote']), isEmpty);
      expect(await deviceTrash.getToTrash(), isEmpty);
      expect((await remote.get('remote'))!.isTrashed, isFalse);
    },
  );

  test('captured device identifier reused for another file is never returned for deletion', () async {
    await remote.trash(['remote']);
    await context.db.localAssetEntity.deleteWhere((row) => row.id.equals('local'));
    await context.newLocalAsset(id: 'local', checksum: 'another-file');
    expect(await sync.getDeletionLocalIds(['remote']), isEmpty);
  });

  test('new checksum-matched device copy is discovered after permanent server deletion', () async {
    await remote.trash(['remote']);
    await sync.retainPermanentDeletion(['remote']);
    await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('remote'));
    await context.db.localAssetEntity.deleteWhere((row) => row.id.equals('local'));
    await context.newLocalAsset(id: 'late-local', checksum: 'checksum');
    expect(await sync.getDeletionLocalIds(['remote']), ['late-local']);
  });
  test('Gallery-only durable intent survives operation acknowledgement, repository restart and sync reset', () async {
    final captured = await remote.beginTrashOperation(['remote'], restore: false);
    await sync.completeTrashOperation(captured, success: true);
    await sync.updateRetainedTrash(['remote'], DateTime.utc(2026, 10, 13), preserveExistingDates: true);
    sync = SyncStreamRepository(context.db);
    expect(await sync.getDeviceTrashSyncIds(['remote']), isEmpty);
    await sync.reset();
    await context.newUser(id: 'owner');
    await context.newAuthUser(id: 'owner');
    await context.newRemoteAsset(id: 'remote', ownerId: 'owner', checksum: 'checksum', deletedAt: DateTime.utc(2026));
    expect(await sync.getDeviceTrashSyncIds(['remote']), isEmpty);
    expect(await deviceTrash.getToTrash(), isEmpty);
  });

  test('a later explicit Restore removes the server-only marker and permits a new remote Trash opt-in', () async {
    final captured = await remote.beginTrashOperation(['remote'], restore: false);
    await sync.completeTrashOperation(captured, success: true);
    final restore = await remote.beginTrashOperation(['remote'], restore: true);
    await sync.completeTrashOperation(restore, success: true);
    await (context.db.remoteAssetEntity.update()..where((row) => row.id.equals('remote'))).write(
      RemoteAssetEntityCompanion(deletedAt: Value(DateTime.utc(2026))),
    );
    expect(await sync.getDeviceTrashSyncIds(['remote']), ['remote']);
    expect((await deviceTrash.getToTrash())['album']!.single.id, 'local');
  });

  test('offline external index tombstones and another owner never become automatic device Trash', () async {
    await (context.db.remoteAssetEntity.update()..where((row) => row.id.equals('remote'))).write(
      RemoteAssetEntityCompanion(deletedAt: Value(DateTime.utc(2026)), isIndexTombstone: const Value(true)),
    );
    await context.newUser(id: 'other-owner');
    await context.newRemoteAsset(
      id: 'other',
      ownerId: 'other-owner',
      checksum: 'checksum',
      deletedAt: DateTime.utc(2026),
    );
    expect(await sync.getDeviceTrashSyncIds(['remote', 'other']), isEmpty);
    expect(await deviceTrash.getToTrash(), isEmpty);
  });

  test(
    'confirmed receipt stays OS-retryable after denial, restart and new local scans; successful OS deletion clears it',
    () async {
      await remote.trash(['remote']);
      await sync.retainPermanentDeletion(['remote']);
      await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('remote'));
      sync = SyncStreamRepository(context.db);
      expect(await sync.getPendingDeviceDeletionAssetIds('owner'), ['remote']);
      await context.db.localAssetEntity.deleteWhere((row) => row.id.equals('local'));
      expect(await sync.getPendingDeviceDeletionAssetIds('owner'), isEmpty);
      await context.newLocalAsset(id: 'rescanned', checksum: 'checksum');
      expect(await sync.getPendingDeviceDeletionAssetIds('owner'), ['remote']);
      expect(await sync.getDeletionLocalIds(['remote']), ['rescanned']);
    },
  );

  test('uncertain permanent intent is never an OS-only retry authorization', () async {
    await remote.trash(['remote']);
    await remote.beginPermanentDeletion(['remote']);
    await sync.recoverPendingTrashOperations();
    expect(await sync.getPendingDeviceDeletionAssetIds('owner'), isEmpty);
  });

  test('completed receipt for another owner is never returned for this account', () async {
    await context.newUser(id: 'other-owner');
    await context.newRemoteAsset(
      id: 'other',
      ownerId: 'other-owner',
      checksum: 'checksum',
      deletedAt: DateTime.utc(2026),
    );
    await sync.retainPermanentDeletion(['other']);
    expect(await sync.getPendingDeviceDeletionAssetIds('owner'), isEmpty);
    expect(await sync.getPendingDeviceDeletionAssetIds('other-owner'), isEmpty);
    expect(await sync.getDeletionLocalIds(['other']), isEmpty);
  });

  test('matching local Trash copy can retry but a reused current OS ID overrides that cached identity', () async {
    await remote.trash(['remote']);
    await sync.retainPermanentDeletion(['remote']);
    await context.newTrashedLocalAsset(id: 'local', albumId: 'album', checksum: 'checksum');
    await context.db.localAssetEntity.deleteWhere((row) => row.id.equals('local'));
    expect(await sync.getPendingDeviceDeletionAssetIds('owner'), ['remote']);
    expect(await sync.getDeletionLocalIds(['remote']), ['local']);
    await context.newLocalAsset(id: 'local', checksum: 'unrelated-file');
    expect(await sync.getPendingDeviceDeletionAssetIds('owner'), isEmpty);
    expect(await sync.getDeletionLocalIds(['remote']), isEmpty);
  });

  test('OS-confirmed permanent removal clears only the selected local Trash cache rows', () async {
    await context.newTrashedLocalAsset(id: 'local', albumId: 'album', checksum: 'checksum');
    await context.newTrashedLocalAsset(id: 'other', albumId: 'album', checksum: 'other');
    await deviceTrash.deleteAssets(['local']);
    final rows = await context.db.trashedLocalAssetEntity.select().get();
    expect(rows.single.id, 'other');
  });
}
