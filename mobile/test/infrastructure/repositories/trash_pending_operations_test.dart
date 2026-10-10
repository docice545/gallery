import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/remote/exif.drift.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_exif.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/repositories/shared_space_api.repository.dart';
import 'package:immich_mobile/services/action.service.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' as dto;
import 'package:openapi/api.dart' show ApiException;

import '../../medium/repository_context.dart';
import '../../repository.mocks.dart';
import '../repository.mock.dart';

class _MockSpaceApi extends Mock implements SharedSpaceApiRepository {}

class _MockApiService extends Mock implements ApiService {}

class _MockAssetsApi extends Mock implements dto.AssetsApi {}

class _MockTrashApi extends Mock implements dto.TrashApi {}

void main() {
  late MediumRepositoryContext ctx;
  late RemoteAssetRepository remote;
  late SyncStreamRepository sync;
  late MockAssetApiRepository api;
  late AssetService assets;
  late ActionService actions;
  final deletionDate = DateTime.utc(2026, 10, 8, 12);

  setUpAll(() {
    registerFallbackValue(dto.BulkIdsDto(ids: []));
    registerFallbackValue(dto.AssetBulkDeleteDto(ids: []));
  });

  setUp(() async {
    ctx = MediumRepositoryContext();
    await ctx.newUser(id: 'owner');
    await ctx.newAuthUser(id: 'owner');
    await ctx.newRemoteAsset(id: 'asset', ownerId: 'owner');
    remote = RemoteAssetRepository(ctx.db);
    sync = SyncStreamRepository(ctx.db);
    api = MockAssetApiRepository();
    assets = AssetService(
      remoteRepository: remote,
      exifRepository: RemoteExifRepository(ctx.db),
      localRepository: LocalAssetRepository(ctx.db),
      apiRepository: api,
      mediaRepository: MockAssetMediaRepository(),
      trashedLocalRepository: TrashedLocalAssetRepository(ctx.db),
    );
    actions = ActionService(api, remote, _MockSpaceApi(), MockAlbumApiRepository(), MockRemoteAlbumRepository());
  });
  tearDown(() => ctx.dispose());

  Future<String?> marker(String id) async {
    final row = await (ctx.db.settingsEntity.select()..where((row) => row.key.like('sync.trash-reset.%/owner/$id')))
        .getSingleOrNull();
    return row?.value;
  }

  test('definite Trash rejection restores the active row and removes its optimistic tombstone', () async {
    when(() => api.delete(['asset'], false)).thenThrow(ApiException(403, 'Forbidden'));
    await expectLater(assets.trash(['asset']), throwsA(isA<ApiException>()));
    expect((await remote.get('asset'))!.isTrashed, isFalse);
    expect(await marker('asset'), isNull);
  });

  test('active sync cannot verify a restore while the Trash request is still in flight', () async {
    final requested = Completer<void>();
    final response = Completer<void>();
    when(() => api.delete(['asset'], false)).thenAnswer((_) {
      requested.complete();
      return response.future;
    });
    final work = assets.trash(['asset']);
    await requested.future;
    try {
      expect((await remote.get('asset'))!.isTrashed, isTrue);
      expect(await sync.getRestoreCandidates({'asset': 'owner'}), isEmpty);
    } finally {
      response.complete();
      await work;
    }
  });

  test('late single Restore acknowledgement does not remove a subsequent Trash revision', () async {
    await ctx.newRemoteAsset(id: 'trashed', ownerId: 'owner', deletedAt: deletionDate);
    final requested = Completer<void>();
    final response = Completer<void>();
    when(() => api.restoreTrash(['trashed'])).thenAnswer((_) {
      requested.complete();
      return response.future;
    });
    final work = assets.restoreTrash(['trashed']);
    await requested.future;
    await remote.trash(['trashed']);
    final latest = await marker('trashed');
    response.complete();
    await work;
    expect(await marker('trashed'), latest);
    expect((await remote.get('trashed'))!.isTrashed, isTrue);
  });

  test('late Restore All acknowledgement does not remove an unrelated new Trash marker', () async {
    await ctx.newRemoteAsset(id: 'trashed', ownerId: 'owner', deletedAt: deletionDate);
    final requested = Completer<void>();
    final response = Completer<int>();
    when(() => api.restoreAllTrash()).thenAnswer((_) {
      requested.complete();
      return response.future;
    });
    final work = actions.restoreAllTrash('owner');
    await requested.future;
    await remote.trash(['asset']);
    final latest = await marker('asset');
    response.complete(1);
    await work;
    expect(await marker('asset'), latest);
    expect((await remote.get('asset'))!.isTrashed, isTrue);
  });

  test('bulk rejected Trash rolls back only its own assets', () async {
    await ctx.newRemoteAsset(id: 'second', ownerId: 'owner');
    await ctx.newRemoteAsset(id: 'already-trash', ownerId: 'owner', deletedAt: deletionDate);
    when(() => api.delete(['asset', 'second', 'already-trash'], false)).thenThrow(ApiException(403, 'Forbidden'));
    await expectLater(assets.trash(['asset', 'second', 'already-trash']), throwsA(isA<ApiException>()));
    expect((await remote.get('asset'))!.isTrashed, isFalse);
    expect((await remote.get('second'))!.isTrashed, isFalse);
    expect((await remote.get('already-trash'))!.deletedAt, deletionDate);
    expect(await marker('asset'), isNull);
    expect(await marker('second'), isNull);
  });

  for (final error in [ApiException(0, 'offline'), ApiException(408, 'timeout'), ApiException(500, 'server error')]) {
    test('Trash ${error.code} retains a durable unknown outcome without assuming server acceptance', () async {
      when(() => api.delete(['asset'], false)).thenThrow(error);
      await expectLater(assets.trash(['asset']), throwsA(same(error)));
      expect((await remote.get('asset'))!.isTrashed, isTrue);
      expect((await sync.getPendingTrashOperations()).map((s) => s.id), ['asset']);
      // A new repository instance sees the same state; ordinary active sync
      // is insufficient to infer the result of the failed mutation request.
      expect(await SyncStreamRepository(ctx.db).getRestoreCandidates({'asset': 'owner'}), isEmpty);
    });
  }

  test(
    'uncertain Restore keeps its optimistic state and original Trash date for authoritative reconciliation',
    () async {
      await ctx.newRemoteAsset(id: 'trashed', ownerId: 'owner', deletedAt: deletionDate);
      when(() => api.restoreTrash(['trashed'])).thenThrow(ApiException(0, 'offline'));
      await expectLater(assets.restoreTrash(['trashed']), throwsA(isA<ApiException>()));
      expect((await remote.get('trashed'))!.isTrashed, isFalse);
      final pending = (await sync.getPendingTrashOperations()).single;
      await sync.reconcilePendingTrash(pending, isTrashed: true);
      expect((await remote.get('trashed'))!.deletedAt, deletionDate);
    },
  );

  test('late rejected Restore cannot roll back a newer optimistic Trash', () async {
    await ctx.newRemoteAsset(id: 'trashed', ownerId: 'owner', deletedAt: deletionDate);
    final restore = await remote.beginTrashOperation(['trashed'], restore: true);
    final trash = await remote.beginTrashOperation(['trashed'], restore: false);
    final latest = await marker('trashed');
    await remote.completeTrashOperation(restore, success: false, definiteFailure: true);
    expect(await marker('trashed'), latest);
    expect((await remote.get('trashed'))!.isTrashed, isTrue);
    await remote.completeTrashOperation(trash, success: true);
    expect(await sync.getPendingTrashOperations(), isEmpty);
    expect((await remote.get('trashed'))!.isTrashed, isTrue);
  });

  test('late Restore All acknowledgement cannot clear subsequent Trash of the same asset', () async {
    await remote.trash(['asset']);
    final restoring = await remote.beginRestoreAllTrash('owner');
    final trashing = await remote.beginTrashOperation(['asset'], restore: false);
    final latest = await marker('asset');
    await remote.completeTrashOperation(restoring, success: true);
    expect(await marker('asset'), latest);
    await remote.completeTrashOperation(trashing, success: true);
    expect((await remote.get('asset'))!.isTrashed, isTrue);
    expect(await marker('asset'), isNotNull);
  });

  for (final bulk in [false, true]) {
    test('real ${bulk ? 'bulk' : 'single'} Restore followed immediately by Trash preserves newest intent', () async {
      await remote.trash(['asset']);
      final service = _MockApiService();
      final assetsApi = _MockAssetsApi();
      final trashApi = _MockTrashApi();
      when(() => service.assetsApi).thenReturn(assetsApi);
      when(() => service.trashApi).thenReturn(trashApi);
      final realApi = AssetApiRepository(service);
      final assetService = AssetService(
        remoteRepository: remote,
        exifRepository: RemoteExifRepository(ctx.db),
        localRepository: LocalAssetRepository(ctx.db),
        apiRepository: realApi,
        mediaRepository: MockAssetMediaRepository(),
        trashedLocalRepository: TrashedLocalAssetRepository(ctx.db),
      );
      final actionService = ActionService(
        realApi,
        remote,
        _MockSpaceApi(),
        MockAlbumApiRepository(),
        MockRemoteAlbumRepository(),
      );
      final restoreStarted = Completer<void>();
      final restored = Completer<dto.TrashResponseDto?>();
      final trashStarted = Completer<void>();
      final trashed = Completer<void>();
      Future<dto.TrashResponseDto?> restoreReply(Invocation _) {
        restoreStarted.complete();
        return restored.future;
      }

      if (bulk) {
        when(() => trashApi.restoreTrash()).thenAnswer(restoreReply);
      } else {
        when(() => trashApi.restoreAssets(any())).thenAnswer(restoreReply);
      }
      when(() => assetsApi.deleteAssets(any())).thenAnswer((_) {
        trashStarted.complete();
        return trashed.future;
      });
      final restoring = bulk ? actionService.restoreAllTrash('owner') : assetService.restoreTrash(['asset']);
      await restoreStarted.future;
      final trashing = assetService.trash(['asset']);
      // Wait for optimistic DB state, which must update without waiting for
      // the earlier HTTP reply. REST calls themselves retain their order.
      await (ctx.db.remoteAssetEntity.select()..where((row) => row.id.equals('asset'))).watchSingle().firstWhere(
        (row) => row.deletedAt != null,
      );
      final latest = await marker('asset');
      restored.complete(dto.TrashResponseDto(count: 1));
      await restoring;
      await trashStarted.future;
      expect(await marker('asset'), latest);
      expect((await remote.get('asset'))!.isTrashed, isTrue);
      trashed.complete();
      await trashing;
      expect((await remote.get('asset'))!.isTrashed, isTrue);
      expect(await sync.getPendingTrashOperations(), isEmpty);
      expect(await marker('asset'), isNotNull);
    });
  }

  test('rejected retrash rolls back UI but keeps a preceding unresolved Restore pending', () async {
    await ctx.newRemoteAsset(id: 'trashed', ownerId: 'owner', deletedAt: deletionDate);
    final restore = await remote.beginTrashOperation(['trashed'], restore: true);
    final trash = await remote.beginTrashOperation(['trashed'], restore: false);
    await remote.completeTrashOperation(restore, success: false, definiteFailure: true);
    await remote.completeTrashOperation(trash, success: false, definiteFailure: true);
    expect((await remote.get('trashed'))!.isTrashed, isFalse); // Rollback to the previous UI.
    final pending = (await sync.getPendingTrashOperations()).single;
    // That UI was optimistic too; the server never restored the original.
    await sync.reconcilePendingTrash(pending, isTrashed: true);
    expect((await remote.get('trashed'))!.deletedAt, deletionDate);
    expect(await sync.getPendingTrashOperations(), isEmpty);
  });

  for (final v2 in [false, true]) {
    test('V${v2 ? 2 : 1} stale payloads preserve in-flight Trash and Restore UI state', () async {
      final payload = {
        'id': 'asset',
        'ownerId': 'owner',
        'checksum': (await remote.get('asset'))!.checksum,
        'originalFileName': 'photo.jpg',
        'type': 'IMAGE',
        'isFavorite': false,
        'fileCreatedAt': deletionDate.toIso8601String(),
        'fileModifiedAt': deletionDate.toIso8601String(),
        'createdAt': deletionDate.toIso8601String(),
        'localDateTime': deletionDate.toIso8601String(),
        'visibility': 'timeline',
        'isEdited': false,
        'duration': v2 ? 0 : null,
        'deletedAt': null,
        'height': null,
        'width': null,
        'libraryId': null,
        'livePhotoVideoId': null,
        'stackId': null,
        'thumbhash': null,
      };
      final trash = await remote.beginTrashOperation(['asset'], restore: false);
      if (v2) {
        await sync.updateAssetsV2([dto.SyncAssetV2.fromJson(payload)!]);
      } else {
        await sync.updateAssetsV1([dto.SyncAssetV1.fromJson(payload)!]);
      }
      expect((await remote.get('asset'))!.isTrashed, isTrue);
      await remote.completeTrashOperation(trash, success: true);
      final restore = await remote.beginTrashOperation(['asset'], restore: true);
      payload['deletedAt'] = deletionDate.toIso8601String();
      if (v2) {
        await sync.updateAssetsV2([dto.SyncAssetV2.fromJson(payload)!]);
      } else {
        await sync.updateAssetsV1([dto.SyncAssetV1.fromJson(payload)!]);
      }
      expect((await remote.get('asset'))!.isTrashed, isFalse);
      await remote.completeTrashOperation(restore, success: true);
      expect(await marker('asset'), isNull);
    });
  }

  test('reset preserves the in-flight revision so stale active replay cannot resurrect Trash', () async {
    final pending = await remote.beginTrashOperation(['asset'], restore: false);
    final before = await marker('asset');
    await sync.reset();
    expect(await marker('asset'), before);
    expect(await sync.getRestoreCandidates({'asset': 'owner'}), isEmpty);
    await remote.completeTrashOperation(pending, success: true);
    expect(await marker('asset'), isNotNull);
  });

  test('abandoned Trash survives SQLite reopen, becomes uncertain and can resolve without replay', () async {
    final directory = await Directory.systemTemp.createTemp('gallery-pending-trash-');
    var cache = Drift(DatabaseConnection(NativeDatabase(File('${directory.path}/cache.sqlite'))));
    addTearDown(() async {
      await cache.close();
      await directory.delete(recursive: true);
    });
    await cache.into(cache.userEntity).insert(await ctx.db.userEntity.select().getSingle());
    await cache.into(cache.authUserEntity).insert(await ctx.db.authUserEntity.select().getSingle());
    await cache.into(cache.remoteAssetEntity).insert(await ctx.db.remoteAssetEntity.select().getSingle());
    await RemoteAssetRepository(cache).beginTrashOperation(['asset'], restore: false);
    await cache.close();
    cache = Drift(DatabaseConnection(NativeDatabase(File('${directory.path}/cache.sqlite'))));
    final reloaded = SyncStreamRepository(cache);
    expect(await reloaded.getPendingTrashOperations(), isEmpty); // Still protected as in-flight.
    await reloaded.recoverPendingTrashOperations();
    final uncertain = (await reloaded.getPendingTrashOperations()).single;
    expect((await RemoteAssetRepository(cache).get('asset'))!.isTrashed, isTrue);
    await reloaded.reconcilePendingTrash(uncertain, isTrashed: false);
    expect((await RemoteAssetRepository(cache).get('asset'))!.isTrashed, isFalse);
    expect(await reloaded.getPendingTrashOperations(), isEmpty);
    expect(await reloaded.getRestoreCandidates({'asset': 'owner'}), isEmpty);
  });

  test('native CMP projection follows Trash/Restore across SQLite restart and delayed sync', () async {
    final projection = await File('android/app/src/main/res/raw/gallery_cloud_media.sql').readAsString();
    final directory = await Directory.systemTemp.createTemp('gallery-cmp-trash-');
    final file = File('${directory.path}/cache.sqlite');
    var cache = Drift(DatabaseConnection(NativeDatabase(file)));
    addTearDown(() async {
      await cache.close();
      await directory.delete(recursive: true);
    });
    await cache.into(cache.userEntity).insert(await ctx.db.userEntity.select().getSingle());
    await cache.into(cache.authUserEntity).insert(await ctx.db.authUserEntity.select().getSingle());
    await cache.into(cache.remoteAssetEntity).insert(await ctx.db.remoteAssetEntity.select().getSingle());
    await cache
        .into(cache.remoteExifEntity)
        .insert(RemoteExifEntityCompanion.insert(assetId: 'asset', fileSize: const Value(200000)));
    Future<List<String>> pickerIds() async =>
        (await cache.customSelect(projection, variables: [const Variable('owner')]).get())
            .map((row) => row.read<String>('asset_id'))
            .toList();
    final checksum = (await RemoteAssetRepository(cache).get('asset'))!.checksum;
    final stale = dto.SyncAssetV2.fromJson({
      'id': 'asset',
      'ownerId': 'owner',
      'checksum': checksum,
      'originalFileName': 'photo.jpg',
      'type': 'IMAGE',
      'isFavorite': false,
      'fileCreatedAt': deletionDate.toIso8601String(),
      'fileModifiedAt': deletionDate.toIso8601String(),
      'createdAt': deletionDate.toIso8601String(),
      'localDateTime': deletionDate.toIso8601String(),
      'visibility': 'timeline',
      'isEdited': false,
      'duration': 0,
      'deletedAt': null,
      'height': null,
      'width': null,
      'libraryId': null,
      'livePhotoVideoId': null,
      'stackId': null,
      'thumbhash': null,
    })!;
    expect(await pickerIds(), ['asset']);
    await RemoteAssetRepository(cache).beginTrashOperation(['asset'], restore: false);
    expect(await pickerIds(), isEmpty);
    await cache.close();
    cache = Drift(DatabaseConnection(NativeDatabase(file)));
    final reloaded = SyncStreamRepository(cache);
    await reloaded.recoverPendingTrashOperations();
    final pending = (await reloaded.getPendingTrashOperations()).single;
    await reloaded.updateAssetsV2([stale]);
    expect(await pickerIds(), isEmpty); // Delayed active payload cannot resurrect pending Trash.
    await reloaded.reconcilePendingTrash(pending, isTrashed: false);
    expect(await pickerIds(), ['asset']); // Reconnect's authoritative rejection, without an asset event.
    final repository = RemoteAssetRepository(cache);
    final trash = await repository.beginTrashOperation(['asset'], restore: false);
    await repository.completeTrashOperation(trash, success: true);
    expect(await pickerIds(), isEmpty);
    final restore = await repository.beginTrashOperation(['asset'], restore: true);
    expect(await pickerIds(), ['asset']);
    final retrash = await repository.beginTrashOperation(['asset'], restore: false);
    await repository.completeTrashOperation(restore, success: true);
    await reloaded.updateAssetsV2([stale]);
    expect(await pickerIds(), isEmpty); // Late Restore reply/sync cannot undo the newer intent.
    await repository.completeTrashOperation(retrash, success: true);
    expect(await pickerIds(), isEmpty);
    expect(await cache.remoteAssetEntity.select().get(), hasLength(1)); // No media removal/duplicate import.
  });
  test('permanent timeout persists its distinct operation across cold-start recovery', () async {
    await remote.trash(['asset']);
    when(() => api.permanentlyDelete(['asset'])).thenThrow(TimeoutException('network'));
    await expectLater(assets.deleteWithResults(['asset']), throwsA(isA<TimeoutException>()));
    final reloaded = SyncStreamRepository(ctx.db);
    await reloaded.recoverPendingTrashOperations();
    final pending = (await reloaded.getPendingTrashOperations()).single;
    expect(jsonDecode(pending.retainedValue!)['operation'], 'permanent');
    expect((await remote.get('asset'))!.isTrashed, isTrue);
    await reloaded.resolvePermanentDeletion(pending, accepted: false);
    expect((await remote.get('asset'))!.isTrashed, isTrue);
    expect(jsonDecode((await marker('asset'))!)['permanent'], isNot(true));
  });

  test('confirmed permanent receipt survives row deletion and a stale Restore acknowledgement', () async {
    await remote.trash(['asset']);
    final restore = await remote.beginTrashOperation(['asset'], restore: true);
    final deletion = await remote.beginPermanentDeletion(['asset']);
    await sync.resolvePermanentDeletion(deletion.single, accepted: true, complete: true);
    await remote.completeTrashOperation(restore, success: true);
    expect(await remote.get('asset'), isNull);
    expect(jsonDecode((await marker('asset'))!)['permanent'], isTrue);
    await remote.deleteAssets(['asset']);
    expect(jsonDecode((await marker('asset'))!)['permanent'], isTrue);
  });

  test(
    'permanent bulk results remove only complete rows; failed remains retryable and blocked stays ordinary Trash',
    () async {
      await ctx.newRemoteAsset(id: 'failed', ownerId: 'owner');
      await ctx.newRemoteAsset(id: 'blocked', ownerId: 'owner');
      await remote.trash(['asset', 'failed', 'blocked']);
      when(() => api.permanentlyDelete(any())).thenAnswer(
        (_) async => [
          const PermanentDeletionResult(id: 'asset', state: 'complete'),
          const PermanentDeletionResult(id: 'failed', state: 'failed', code: 'ORIGINAL_DELETE_FAILED'),
          const PermanentDeletionResult(id: 'blocked', state: 'blocked', code: 'LIBRARY_DELETION_NOT_AUTHORIZED'),
        ],
      );
      final results = await assets.deleteWithResults(['asset', 'failed', 'blocked']);
      expect(results.where((result) => result.complete).map((result) => result.id), ['asset']);
      expect(await remote.get('asset'), isNull);
      expect((await remote.get('failed'))!.isTrashed, isTrue);
      expect((await remote.get('blocked'))!.isTrashed, isTrue);
      expect(jsonDecode((await marker('failed'))!)['permanent'], isTrue);
      expect(jsonDecode((await marker('blocked'))!)['permanent'], isNot(true));
    },
  );
  test('retains the OS identity after server deletion and blocks stale active sync without a ghost row', () async {
    final before = (await remote.get('asset'))!;
    final local = await ctx.newLocalAsset(checksum: before.checksum);
    await remote.trash(['asset']);
    final snapshots = await remote.beginPermanentDeletion(['asset']);
    await sync.resolvePermanentDeletion(snapshots.single, accepted: true, complete: true);
    expect(await remote.getDeletionLocalIds(['asset']), [local.id]);
    final stale = dto.SyncAssetV2.fromJson({
      'id': 'asset',
      'ownerId': 'owner',
      'checksum': before.checksum,
      'originalFileName': 'photo.jpg',
      'type': 'IMAGE',
      'isFavorite': false,
      'fileCreatedAt': deletionDate.toIso8601String(),
      'fileModifiedAt': deletionDate.toIso8601String(),
      'createdAt': deletionDate.toIso8601String(),
      'localDateTime': deletionDate.toIso8601String(),
      'visibility': 'timeline',
      'isEdited': false,
      'duration': 0,
      'deletedAt': null,
      'height': null,
      'width': null,
      'libraryId': null,
      'livePhotoVideoId': null,
      'stackId': null,
      'thumbhash': null,
    })!;
    await SyncStreamRepository(ctx.db).updateAssetsV2([stale]);
    expect(await remote.get('asset'), isNull);
    expect(await remote.getDeletionLocalIds(['asset']), [local.id]);
    await remote.restoreTrash(['asset']);
    expect(jsonDecode((await marker('asset'))!)['permanentComplete'], isTrue);
  });
}
