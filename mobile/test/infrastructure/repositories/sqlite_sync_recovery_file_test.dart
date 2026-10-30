import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/app/settings.drift.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_recovery.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:openapi/api.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

SyncUserV1 _owner() => SyncUserV1(
  id: 'owner',
  email: 'owner@example.test',
  name: 'Owner',
  deletedAt: null,
  avatarColor: const Optional.absent(),
  hasProfileImage: false,
  profileChangedAt: DateTime(2026, 10, 29),
);

SyncAssetV2 _asset({required String id, required String checksum}) => SyncAssetV2(
  id: id,
  checksum: checksum,
  originalFileName: '$id.jpg',
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

Future<Uint8List> corruptOwnerChecksumIndex(File database) async {
  final raw = sqlite.sqlite3.open(database.path);
  final pageSize = raw.select('PRAGMA page_size').single.values.single as int;
  final indexRoot = raw
      .select("SELECT rootpage FROM sqlite_master WHERE type = 'index' AND name = 'UQ_remote_assets_owner_checksum'")
      .single.values.single as int;
  raw.close();

  final bytes = await database.readAsBytes();
  final pageOffset = (indexRoot - 1) * pageSize;
  final page = ByteData.sublistView(bytes, pageOffset, pageOffset + pageSize);
  final cellCount = page.getUint16(3, Endian.big);
  final cellContentOffset = page.getUint16(5, Endian.big);
  expect(cellCount, greaterThan(1));
  expect(cellContentOffset + 5, lessThan(pageSize));

  // Corrupt the serial-type byte in an index cell. The table remains readable,
  // but an INSERT OR REPLACE on remote_asset_entity raises result code 779.
  page.setUint8(cellContentOffset + 5, 0);
  await database.writeAsBytes(bytes, flush: true);
  return database.readAsBytes();
}

void main() {
  test('updateAssetsV2 detects 779, snapshots, preserves pending state, and resumes on repaired copy', () async {
    SqliteRecoveryGate.clearAfterValidatedRecovery();
    final root = await Directory.systemTemp.createTemp('foto-sync-corruption-');
    addTearDown(() => root.delete(recursive: true));

    final primary = File('${root.path}/immich.sqlite');
    final snapshots = Directory('${root.path}/snapshots');
    Drift? db;
    Drift? candidateDb;
    SqliteRecoverySnapshot? captured;
    const pendingKey = 'sync.pending.synthetic';
    const cursorKey = 'sync.cursor.synthetic';
    const pendingValue = '{"operation":"upload","assetId":"pending-asset"}';
    const cursorValue = 'ack-before-corruption';

    try {
      db = Drift(drift.DatabaseConnection(NativeDatabase(primary), closeStreamsSynchronously: true));
      final repository = SyncStreamRepository(db!);
      await repository.updateUsersV1([_owner()]);
      await db!.into(db!.settingsEntity).insert(
        SettingsEntityCompanion.insert(key: pendingKey, value: const drift.Value(pendingValue)),
      );
      await db!.into(db!.settingsEntity).insert(
        SettingsEntityCompanion.insert(key: cursorKey, value: const drift.Value(cursorValue)),
      );

      final seed = [
        for (var index = 1; index <= 100; index++)
          _asset(id: 'asset-$index', checksum: 'checksum-${index.toString().padLeft(3, '0')}'),
      ];
      await repository.updateAssetsV2(seed);
      await db!.close();
      db = null;

      final corruptedBytes = await corruptOwnerChecksumIndex(primary);
      db = Drift(drift.DatabaseConnection(NativeDatabase(primary), closeStreamsSynchronously: true));
      final failingAsset = _asset(id: 'asset-1', checksum: 'checksum-recovered');
      final failingRepository = SyncStreamRepository(
        db!,
        recoverySnapshotCapture: ({required debugLabel, required error}) async {
          captured = await captureSqliteRecoverySnapshot(
            database: primary,
            outputDirectory: snapshots,
            reason: 'test $debugLabel SQLite result ${error.extendedResultCode}',
          );
          return captured;
        },
      );

      await expectLater(
        failingRepository.updateAssetsV2([failingAsset], debugLabel: 'file-backed-test'),
        throwsA(
          isA<SqliteDatabaseUnhealthy>().having(
            (error) => error.cause,
            'cause',
            779,
          ),
        ),
      );
      expect(SqliteRecoveryGate.isHalted, isTrue);
      expect(captured, isNotNull);
      expect(await primary.readAsBytes(), corruptedBytes);
      expect(
        (await db!.settingsEntity.select().get()).where((row) => row.key == pendingKey).single.value,
        pendingValue,
      );
      expect(
        (await db!.settingsEntity.select().get()).where((row) => row.key == cursorKey).single.value,
        cursorValue,
      );
      await db!.close();
      db = null;

      final report = await diagnoseAndRepairSqliteSnapshot(
        snapshot: captured!.directory,
        outputDirectory: Directory('${root.path}/candidates'),
      );
      expect(report.status, SqliteRecoveryStatus.repairedIndex);
      expect(report.candidate, isNotNull);
      expect(report.toJson()['promotionAllowed'], isFalse);

      SqliteRecoveryGate.clearAfterValidatedRecovery();
      final candidateFile = File('${report.candidate!.path}/immich.sqlite');
      candidateDb = Drift(
        drift.DatabaseConnection(NativeDatabase(candidateFile), closeStreamsSynchronously: true),
      );
      final candidateRepository = SyncStreamRepository(candidateDb!);
      await candidateRepository.updateAssetsV2([failingAsset], debugLabel: 'file-backed-resume');
      final candidateRow = await (candidateDb!.remoteAssetEntity.select()..where((row) => row.id.equals('asset-1')))
          .getSingle();
      expect(candidateRow.checksum, 'checksum-recovered');
      expect(
        (await candidateDb!.settingsEntity.select().get()).where((row) => row.key == pendingKey).single.value,
        pendingValue,
      );
      expect(
        (await candidateDb!.settingsEntity.select().get()).where((row) => row.key == cursorKey).single.value,
        cursorValue,
      );
      await candidateDb!.close();
      candidateDb = null;

      // The repaired candidate continues the exact event while the primary
      // remains untouched and still requires explicit promotion approval.
      expect(await primary.readAsBytes(), corruptedBytes);
    } finally {
      await db?.close();
      await candidateDb?.close();
      SqliteRecoveryGate.clearAfterValidatedRecovery();
    }
  });
}
