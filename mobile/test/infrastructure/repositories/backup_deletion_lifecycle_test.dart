import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/hash.service.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/utils/option.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' as api;

import '../../medium/repository_context.dart';
import '../../service.mocks.dart';

void main() {
  late MediumRepositoryContext context;
  late BackupRepository backup;
  late RemoteAssetRepository remote;
  late SyncStreamRepository sync;
  final date = DateTime.utc(2026, 10, 13, 10);

  setUp(() async {
    context = MediumRepositoryContext();
    backup = BackupRepository(context.db);
    remote = RemoteAssetRepository(context.db);
    sync = SyncStreamRepository(context.db);
    await context.newUser(id: 'owner');
    await context.newAuthUser(id: 'owner');
    await StoreRepository(context.db).upsert(StoreKey.serverEndpoint, 'https://gallery.invalid/api');
    await context.newLocalAlbum(id: 'camera', backupSelection: BackupSelection.selected);
    await context.newLocalAsset(id: 'local', checksum: 'original-bytes', createdAt: date);
    await context.newLocalAlbumAsset(albumId: 'camera', assetId: 'local');
  });

  tearDown(() => context.dispose());

  Future<void> seedRemote() =>
      context.newRemoteAsset(id: 'remote', ownerId: 'owner', checksum: 'original-bytes', createdAt: date);

  Future<List<String>> candidates({String owner = 'owner', bool onlyHashed = true}) async =>
      (await backup.getCandidates(owner, onlyHashed: onlyHashed)).map((asset) => asset.id).toList();

  Future<void> replaceDeviceBytes(String? checksum) =>
      (context.db.localAssetEntity.update()..where((row) => row.id.equals('local'))).write(
        LocalAssetEntityCompanion(checksum: Value(checksum)),
      );

  api.SyncAssetV2 serverSnapshot({DateTime? deletedAt, bool isTrashed = false}) => api.SyncAssetV2.fromJson({
    'id': 'remote',
    'checksum': 'original-bytes',
    'originalFileName': 'synthetic.jpg',
    'type': 'IMAGE',
    'ownerId': 'owner',
    'isFavorite': false,
    'fileCreatedAt': date.toIso8601String(),
    'fileModifiedAt': date.toIso8601String(),
    'createdAt': date.toIso8601String(),
    'localDateTime': date.toIso8601String(),
    'visibility': 'timeline',
    'width': 100,
    'height': 100,
    'deletedAt': deletedAt?.toIso8601String(),
    'isTrashed': isTrashed,
    'duration': null,
    'libraryId': 'external',
    'livePhotoVideoId': null,
    'stackId': null,
    'thumbhash': null,
    'isEdited': false,
  })!;

  test('selected active photos and videos remain automatic backup candidates without server state', () async {
    await context.newLocalAsset(id: 'video', checksum: 'video-bytes', type: AssetType.video, createdAt: date);
    await context.newLocalAlbumAsset(albumId: 'camera', assetId: 'video');
    expect(await candidates(), unorderedEquals(['local', 'video']));
    expect(await backup.getAllCounts('owner'), (total: 2, remainder: 2, processing: 0));
  });

  test('another owner server copy and Trash markers cannot suppress the current owner backup', () async {
    await context.newUser(id: 'other');
    await context.newRemoteAsset(id: 'other-remote', ownerId: 'other', checksum: 'original-bytes');
    await remote.trash(['other-remote']);
    await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('other-remote'));
    expect(await candidates(), ['local']);
    expect((await backup.getAllCounts('owner')).remainder, 1);
  });

  test('offline external index tombstone creates no durable user deletion or backup suppression', () async {
    await sync.updateAssetsV2([serverSnapshot(deletedAt: date)]);
    final offline = await context.db.remoteAssetEntity.select().getSingle();
    expect(offline.isIndexTombstone, isTrue);
    expect(await context.db.settingsEntity.select().get(), isEmpty);
    // A server-side index row still means these bytes already exist remotely.
    expect(await candidates(), isEmpty);
    await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('remote'));
    expect(await candidates(), ['local']);
    expect((await backup.getAllCounts('owner')).remainder, 1);
  });

  test('uncertain Trash after offline interruption blocks only its bytes and preserves new uploads', () async {
    await seedRemote();
    final pending = await remote.beginTrashOperation(['remote'], restore: false);
    await sync.completeTrashOperation(pending, success: false);
    await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('remote'));
    await context.newLocalAsset(id: 'new-photo', checksum: 'new-bytes', createdAt: date);
    await context.newLocalAlbumAsset(albumId: 'camera', assetId: 'new-photo');
    sync = SyncStreamRepository(context.db);
    await sync.recoverPendingTrashOperations();
    expect(await sync.getPendingTrashOperations(), hasLength(1));
    expect(await candidates(), ['new-photo']);
    expect(await backup.getAllCounts('owner'), (total: 1, remainder: 1, processing: 0));
  });

  test('definite Trash rejection leaves no durable upload ban', () async {
    await seedRemote();
    final pending = await remote.beginTrashOperation(['remote'], restore: false);
    await sync.completeTrashOperation(pending, success: false, definiteFailure: true);
    expect(await context.db.settingsEntity.select().get(), isEmpty);
    await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('remote'));
    expect(await candidates(), ['local']);
  });

  test('confirmed Restore restores ordinary backup counts without duplicating its server asset', () async {
    await seedRemote();
    await remote.trash(['remote']);
    expect(await backup.getAllCounts('owner'), (total: 0, remainder: 0, processing: 0));
    final restore = await remote.beginTrashOperation(['remote'], restore: true);
    expect(await candidates(), isEmpty);
    await sync.completeTrashOperation(restore, success: true);
    expect(await context.db.settingsEntity.select().get(), isEmpty);
    expect(await backup.getAllCounts('owner'), (total: 1, remainder: 0, processing: 0));
    expect(await candidates(), isEmpty);
    // Restore does not change the user's album selections or invent device files.
    expect((await context.db.localAlbumEntity.select().getSingle()).backupSelection, BackupSelection.selected);
    expect((await context.db.localAssetEntity.select().get()).map((asset) => asset.id), ['local']);
  });

  test('late Restore acknowledgement cannot clear a newer Trash upload ban', () async {
    await seedRemote();
    await remote.trash(['remote']);
    final restore = await remote.beginTrashOperation(['remote'], restore: true);
    await remote.beginTrashOperation(['remote'], restore: false);
    await sync.completeTrashOperation(restore, success: true);
    await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('remote'));
    expect(await candidates(), isEmpty);
    expect((await backup.getAllCounts('owner')).remainder, 0);
  });

  test('deletion from another endpoint does not suppress active uploads to this endpoint', () async {
    await seedRemote();
    await remote.trash(['remote']);
    await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('remote'));
    await StoreRepository(context.db).upsert(StoreKey.serverEndpoint, 'https://another-gallery.invalid/api');
    expect(await candidates(), ['local']);
    expect((await backup.getAllCounts('owner')).remainder, 1);
  });

  test('confirmed permanent deletion suppresses checksum-matched rescans with new OS IDs', () async {
    await seedRemote();
    await remote.trash(['remote']);
    await sync.retainPermanentDeletion(['remote']);
    await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('remote'));
    await context.db.localAssetEntity.deleteWhere((row) => row.id.equals('local'));
    await context.newLocalAsset(id: 'rescanned', checksum: 'original-bytes', createdAt: date);
    await context.newLocalAlbumAsset(albumId: 'camera', assetId: 'rescanned');
    expect(await candidates(), isEmpty);
    expect(await backup.getAllCounts('owner'), (total: 0, remainder: 0, processing: 0));
  });

  test('reused OS ID with verified new bytes remains eligible after permanent deletion', () async {
    await seedRemote();
    await remote.trash(['remote']);
    await sync.retainPermanentDeletion(['remote']);
    await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('remote'));
    await context.db.localAlbumAssetEntity.deleteWhere((row) => row.assetId.equals('local'));
    await context.db.localAssetEntity.deleteWhere((row) => row.id.equals('local'));
    await context.newLocalAsset(id: 'local', checksum: 'new-photo-bytes', createdAt: date);
    await context.newLocalAlbumAsset(albumId: 'camera', assetId: 'local');
    expect(await candidates(), ['local']);
    expect(await backup.getAllCounts('owner'), (total: 1, remainder: 1, processing: 0));
    expect(await sync.getDeletionLocalIds(['remote']), isEmpty);
  });

  test('known deleted OS ID waits for hashing; verified new bytes then become backup eligible', () async {
    await seedRemote();
    await remote.trash(['remote']);
    await sync.retainPermanentDeletion(['remote']);
    await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('remote'));
    await replaceDeviceBytes(null);
    expect(await candidates(onlyHashed: false), isEmpty);
    expect(await backup.getAllCounts('owner'), (total: 0, remainder: 0, processing: 0));
    await replaceDeviceBytes('verified-replacement');
    expect(await candidates(), ['local']);
    expect(await backup.getAllCounts('owner'), (total: 1, remainder: 1, processing: 0));
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final sameBytes in [false, true]) {
      test(
        '${platform.name} normal hash pipeline discovers reused OS ID with ${sameBytes ? 'old' : 'new'} bytes',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          await seedRemote();
          await remote.trash(['remote']);
          await sync.retainPermanentDeletion(['remote']);
          await context.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('remote'));
          await context.db.localAlbumAssetEntity.deleteWhere((row) => row.assetId.equals('local'));
          await context.db.localAssetEntity.deleteWhere((row) => row.id.equals('local'));
          await context.newLocalAsset(id: 'local', checksumOption: const Option.none(), createdAt: date);
          await context.newLocalAlbumAsset(albumId: 'camera', assetId: 'local');
          expect(await candidates(onlyHashed: false), isEmpty);

          final native = MockNativeSyncApi();
          final hashing = Completer<void>();
          final result = Completer<List<HashResult>>();
          when(() => native.hashAssets(['local'], allowNetworkAccess: true)).thenAnswer((_) {
            hashing.complete();
            return result.future;
          });
          final service = HashService(
            localAlbumRepository: LocalAlbumRepository(context.db),
            localAssetRepository: LocalAssetRepository(context.db),
            trashedLocalAssetRepository: TrashedLocalAssetRepository(context.db),
            nativeSyncApi: native,
            rethrowErrors: true,
          );
          // HashService uses selected albums + all unhashed rows, independently
          // of backup candidates/counts. A deletion marker cannot strand this ID.
          final task = service.hashAssets();
          await hashing.future.timeout(const Duration(seconds: 2));
          expect(await candidates(), isEmpty); // No unverified upload during hash.
          result.complete([
            HashResult(assetId: 'local', hash: sameBytes ? 'original-bytes' : 'verified-reused-id-bytes'),
          ]);
          await task;

          expect(await candidates(), sameBytes ? isEmpty : ['local']);
          expect(await backup.getAllCounts('owner'), (
            total: sameBytes ? 0 : 1,
            remainder: sameBytes ? 0 : 1,
            processing: 0,
          ));
          expect(await sync.getDeletionLocalIds(['remote']), sameBytes ? ['local'] : isEmpty);
          verify(() => native.hashAssets(['local'], allowNetworkAccess: true)).called(1);
        },
      );
    }
  }

  test('new unknown file remains processing and eligible for hash even while another asset is deleted', () async {
    await seedRemote();
    await remote.trash(['remote']);
    await context.newLocalAsset(id: 'new-unhashed', checksumOption: const Option.none(), createdAt: date);
    await context.newLocalAlbumAsset(albumId: 'camera', assetId: 'new-unhashed');
    expect(await candidates(), isEmpty);
    expect(await candidates(onlyHashed: false), ['new-unhashed']);
    expect(await backup.getAllCounts('owner'), (total: 1, remainder: 1, processing: 1));
  });

  test(
    'offline database restart and stale reconnect retain deletion without suppressing an unrelated upload',
    () async {
      await seedRemote();
      final pending = await remote.beginTrashOperation(['remote'], restore: false);
      await sync.completeTrashOperation(pending, success: false);
      await context.newLocalAsset(id: 'new-photo', checksum: 'new-bytes', createdAt: date);
      await context.newLocalAlbumAsset(albumId: 'camera', assetId: 'new-photo');
      final directory = await Directory.systemTemp.createTemp('gallery-backup-restart-');
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
      for (final row in await context.db.localAlbumEntity.select().get()) {
        await cache.into(cache.localAlbumEntity).insert(row);
      }
      for (final row in await context.db.localAssetEntity.select().get()) {
        await cache.into(cache.localAssetEntity).insert(row);
      }
      for (final row in await context.db.localAlbumAssetEntity.select().get()) {
        await cache.into(cache.localAlbumAssetEntity).insert(row);
      }
      for (final row in await context.db.settingsEntity.select().get()) {
        await cache.into(cache.settingsEntity).insert(row);
      }
      for (final row in await context.db.storeEntity.select().get()) {
        await cache.into(cache.storeEntity).insert(row);
      }
      await cache.close();
      cache = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
      final restarted = BackupRepository(cache);
      final restartedSync = SyncStreamRepository(cache);
      await restartedSync.recoverPendingTrashOperations();
      expect((await restarted.getCandidates('owner')).map((asset) => asset.id), ['new-photo']);
      // An old active page must not clear an unresolved Trash tombstone.
      await restartedSync.updateAssetsV2([serverSnapshot()]);
      expect((await restarted.getCandidates('owner')).map((asset) => asset.id), ['new-photo']);
      expect(await restarted.getAllCounts('owner'), (total: 1, remainder: 1, processing: 0));
      expect((await restartedSync.getPendingTrashOperations()).single.id, 'remote');
    },
  );
}
