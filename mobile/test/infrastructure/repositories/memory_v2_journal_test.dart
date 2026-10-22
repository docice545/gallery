import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/user/auth_user.drift.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:openapi/api.dart';

const endpoint = 'https://synthetic.invalid/api';
final event = SyncMemoryAssetV1(memoryId: 'memory-1', assetId: 'asset-1');
Drift openDb(String path) =>
    Drift(drift.DatabaseConnection(NativeDatabase(File(path)), closeStreamsSynchronously: true));

Future<void> scope(Drift db) async {
  await StoreRepository(db).upsert(StoreKey.serverEndpoint, endpoint);
  await db.authUserEntity.insertOne(
    AuthUserEntityCompanion.insert(id: 'owner', name: 'Owner', email: 'owner@test', avatarColor: AvatarColor.primary),
  );
}

Future<void> parents(SyncStreamRepository repo, {String owner = 'owner'}) async {
  await repo.updateUsersV1([
    SyncUserV1(
      id: owner,
      name: 'Owner',
      email: 'owner@test',
      deletedAt: null,
      avatarColor: const Optional.absent(),
      hasProfileImage: false,
      profileChangedAt: DateTime(2026),
    ),
  ]);
  await repo.updateMemoriesV2([
    SyncMemoryV2.fromJson({
      'id': 'memory-1',
      'ownerId': owner,
      'type': 'on_this_day',
      'data': {'year': 2025},
      'isSaved': false,
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-01T00:00:00Z',
      'memoryAt': '2026-01-01T00:00:00Z',
      'deletedAt': null,
      'seenAt': null,
      'showAt': null,
      'hideAt': null,
    })!,
  ]);
  await repo.updateAssetsV1([
    SyncAssetV1(
      id: 'asset-1',
      checksum: 'synthetic-checksum',
      originalFileName: 'synthetic.jpg',
      type: AssetTypeEnum.IMAGE,
      ownerId: owner,
      isFavorite: false,
      fileCreatedAt: DateTime(2026),
      fileModifiedAt: DateTime(2026),
      createdAt: DateTime(2026),
      localDateTime: DateTime(2026),
      visibility: AssetVisibility.timeline,
      width: 1,
      height: 1,
      deletedAt: null,
      duration: null,
      libraryId: null,
      livePhotoVideoId: null,
      stackId: null,
      thumbhash: null,
      isEdited: false,
    ),
  ]);
}

Future<int> pending(Drift db) async =>
    (await (db.settingsEntity.select()..where((row) => row.key.startsWith('sync.memory-links.v2.'))).get()).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final phase = Platform.environment['FOTO_V2_CRASH_PHASE'];
  final path = Platform.environment['FOTO_V2_CRASH_DB'];
  if (phase != null && path != null) {
    test('PR7 actual process crash $phase', () async {
      final db = openDb(path);
      final repo = SyncStreamRepository(db);
      if (phase == 'writer') {
        await scope(db);
        await repo.updateMemoryAssetsV2([event]);
        expect(await pending(db), 1);
        await File('$path.committed').writeAsString('SQLite commit completed before ACK', flush: true);
        // The CI parent sends SIGKILL; no close/dispose/finally runs here.
        await Completer<void>().future;
      } else {
        expect(await pending(db), 1);
        await repo.updateMemoryAssetsV2([event]); // replay after unknown ACK outcome
        await parents(repo);
        await repo.flushDeferredMemoryAssetsV2();
        await repo.updateMemoryAssetsV2([event]);
        await repo.flushDeferredMemoryAssetsV2();
        expect(await pending(db), 0);
        expect(await db.memoryAssetEntity.select().get(), hasLength(1));
        await db.close();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
    return;
  }

  late Directory temp;
  late String file;
  late Drift db;
  late SyncStreamRepository repo;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('foto-memory-v2-');
    file = '${temp.path}/test.sqlite';
    db = openDb(file);
    repo = SyncStreamRepository(db);
    await scope(db);
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  test('PR7 durable V2 survives connection restart and duplicate redelivery', () async {
    await repo.updateMemoryAssetsV2([event, event]);
    await repo.flushDeferredMemoryAssetsV2(); // missing parents are retained
    expect(await pending(db), 1);
    await db.close();
    db = openDb(file);
    repo = SyncStreamRepository(db);
    await parents(repo);
    await repo.updateMemoryAssetsV2([event]);
    await repo.flushDeferredMemoryAssetsV2();
    await repo.updateMemoryAssetsV2([event]);
    await repo.flushDeferredMemoryAssetsV2();
    expect(await pending(db), 0);
    expect(await db.memoryAssetEntity.select().get(), hasLength(1));
  });

  test('PR7 durable V2 write failure leaves no journal receipt', () async {
    await db.customStatement(
      "CREATE TRIGGER reject_journal BEFORE INSERT ON settings WHEN NEW.key LIKE 'sync.memory-links.v2.%' BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );
    await expectLater(repo.updateMemoryAssetsV2([event]), throwsA(anything));
    expect(await pending(db), 0);
    await db.customStatement('DROP TRIGGER reject_journal');
    await repo.updateMemoryAssetsV2([event]);
    expect(await pending(db), 1);
  });

  test('PR7 durable V2 projection and journal removal roll back together', () async {
    await repo.updateMemoryAssetsV2([event]);
    await parents(repo);
    await db.customStatement(
      "CREATE TRIGGER reject_removal BEFORE DELETE ON settings WHEN OLD.key LIKE 'sync.memory-links.v2.%' BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );
    await expectLater(repo.flushDeferredMemoryAssetsV2(), throwsA(anything));
    expect(await pending(db), 1);
    expect(await db.memoryAssetEntity.select().get(), isEmpty);
    await db.customStatement('DROP TRIGGER reject_removal');
    await repo.flushDeferredMemoryAssetsV2();
    expect(await pending(db), 0);
    expect(await db.memoryAssetEntity.select().get(), hasLength(1));
  });

  test('PR7 durable V2 link delete cancels pending intent across restart', () async {
    await repo.updateMemoryAssetsV2([event]);
    await repo.deleteMemoryAssetsV1([SyncMemoryAssetDeleteV1(memoryId: event.memoryId, assetId: event.assetId)]);
    await db.close();
    db = openDb(file);
    repo = SyncStreamRepository(db);
    await parents(repo);
    await repo.flushDeferredMemoryAssetsV2();
    expect(await pending(db), 0);
    expect(await db.memoryAssetEntity.select().get(), isEmpty);
  });

  test('PR7 durable V2 memory delete and reset cannot resurrect pending links', () async {
    await repo.updateMemoryAssetsV2([event]);
    await repo.deleteMemoriesV1([SyncMemoryDeleteV1(memoryId: event.memoryId)]);
    expect(await pending(db), 0);
    await repo.updateMemoryAssetsV2([event]);
    await repo.reset(retainTrash: false);
    expect(await pending(db), 0);
  });

  test('PR7 durable V2 server scope isolation preserves the other journal', () async {
    await repo.updateMemoryAssetsV2([event]);
    await parents(repo);
    await StoreRepository(db).upsert(StoreKey.serverEndpoint, 'https://another.synthetic.invalid/api');
    await repo.flushDeferredMemoryAssetsV2();
    expect(await pending(db), 1);
    expect(await db.memoryAssetEntity.select().get(), isEmpty);
    await StoreRepository(db).upsert(StoreKey.serverEndpoint, endpoint);
    await repo.flushDeferredMemoryAssetsV2();
    expect(await db.memoryAssetEntity.select().get(), hasLength(1));
  });

  test('PR7 durable V2 foreign memory owner fails without consumption', () async {
    await repo.updateMemoryAssetsV2([event]);
    await parents(repo, owner: 'different-owner');
    await expectLater(repo.flushDeferredMemoryAssetsV2(), throwsA(isA<StateError>()));
    expect(await pending(db), 1);
    expect(await db.memoryAssetEntity.select().get(), isEmpty);
  });
}
