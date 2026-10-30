import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:openapi/api.dart';

void main() {
  late Drift db;
  late SyncStreamRepository repository;

  setUp(() async {
    SqliteRecoveryGate.clearAfterValidatedRecovery();
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    repository = SyncStreamRepository(db);
    await repository.updateUsersV1([
      SyncUserV1(
        id: 'owner',
        email: 'owner@example.test',
        name: 'Owner',
        deletedAt: null,
        avatarColor: const Optional.absent(),
        hasProfileImage: false,
        profileChangedAt: DateTime(2026, 10, 29),
      ),
    ]);
  });

  tearDown(() async {
    SqliteRecoveryGate.clearAfterValidatedRecovery();
    await db.close();
  });

  test('continues updateAssetsV2 only after the recovery gate is cleared', () async {
    final asset = SyncAssetV2(
      id: 'asset-after-recovery',
      checksum: 'checksum-after-recovery',
      originalFileName: 'asset.jpg',
      type: AssetTypeEnum.IMAGE,
      ownerId: 'owner',
      isFavorite: false,
      fileCreatedAt: DateTime(2026, 10, 29),
      fileModifiedAt: DateTime(2026, 10, 29),
      createdAt: DateTime(2026, 10, 29),
      localDateTime: DateTime(2026, 10, 29),
      visibility: AssetVisibility.timeline,
      width: 100,
      height: 100,
      deletedAt: null,
      duration: null,
      libraryId: null,
      livePhotoVideoId: null,
      stackId: null,
      thumbhash: null,
      isEdited: false,
    );

    SqliteRecoveryGate.markRequired(check: 'updateAssetsV2[user]', resultCode: 779);
    await expectLater(repository.updateAssetsV2([asset]), throwsA(isA<SqliteDatabaseUnhealthy>()));
    expect(await db.remoteAssetEntity.select().get(), isEmpty);

    // A validated copy may be restored through the approved user flow. Only
    // that explicit clear permits the stream to continue writing normally.
    SqliteRecoveryGate.clearAfterValidatedRecovery();
    await repository.updateAssetsV2([asset]);
    expect((await db.remoteAssetEntity.select().get()).single.id, asset.id);
  });
}
