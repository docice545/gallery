import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_fresh_start.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fixtures/recovery_http_server.dart';
import 'fixtures/sqlite_account_fixture.dart';
import 'sqlite_one_tap_recovery_test.dart' show FileRecoveryHost;

/// Only the platform capability is substituted. SQLite, production migrations,
/// account encoding, HTTP verification and file generations are real. SAF ZIP
/// readback/fsync/capability enforcement are tested natively and on Android.
class TestFreshHost implements FreshStartHost {
  @override
  final FileRecoveryHost recovery;
  Map<String, String>? _exported;
  bool cancelExport = false;
  bool uploadsStopped = false;
  TestFreshHost(this.recovery);
  @override
  Future<VerifiedRecoveryExport?> exportVerified() async {
    if (cancelExport) {
      return null;
    }
    _exported = await recoveryFileHashes(recovery.source);
    await captureSqliteRecoverySnapshot(
      database: recovery.source,
      outputDirectory: Directory('${recovery.root.path}/external-capability-fixture'),
    );
    return const VerifiedRecoveryExport('native-capability-test-double', 'synthetic-external-zip-checksum');
  }

  @override
  Future<({File source, Directory root, String token})> beginFresh(String exportToken) async {
    if (_exported == null || exportToken != 'native-capability-test-double') {
      throw const RecoveryRefused('external_backup_unverified');
    }
    expect(await recoveryFileHashes(recovery.source), _exported);
    return recovery.begin();
  }

  @override
  Future<void> cancelOldUploads() async => uploadsStopped = true;
  @override
  Future<void> promoteFresh(String token, File candidate, String hash) async {
    expect(uploadsStopped, true);
    expect(await recoveryFileHashes(recovery.source), _exported);
    await recovery.promote(token, candidate, hash);
  }
}

void main() {
  late Directory directory;
  late RecoveryHttpServer server;
  late File source;
  late TestFreshHost host;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('foto24-fresh-');
    server = await RecoveryHttpServer.start();
    source = await createAccountRecoveryFixture(directory, checkpoint: true, endpoint: server.endpoint);
    final legacy = sqlite3.open(source.path, mode: OpenMode.readOnly);
    legacy.select('PRAGMA quick_check(1)');
    legacy.close();
    host = TestFreshHost(FileRecoveryHost(source, Directory('${directory.path}/recovery')));
  });
  tearDown(() async {
    await server.close();
    await directory.delete(recursive: true);
  });

  test('explicit fresh start from Samsung WAL opens verified existing account with no old queues or backup', () async {
    final before = await recoveryFileHashes(source);
    final operation = FreshSqliteStart(host);
    final preparation = (await operation.prepare())!;
    expect(preparation.needsLogin, false);
    await expectLater(operation.run(preparation, consent: false), throwsA(isA<RecoveryRefused>()));
    expect(host.recovery.selection.existsSync(), false);
    expect(host.uploadsStopped, false);
    await operation.run(preparation, consent: true);
    final db = Drift(NativeDatabase(host.recovery.selected));
    final store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    try {
      expect(store.get(StoreKey.currentUser).id, 'existing-owner');
      expect(store.get(StoreKey.accessToken), 'synthetic-token-stays-private');
      expect(store.get(StoreKey.serverUrl), server.endpoint.replaceFirst('/api', ''));
      expect(store.get(StoreKey.manageLocalMediaAndroid), false);
      expect(store.get(StoreKey.recoveryFreshStartReview), true);
      expect(store.get(StoreKey.recoveryFreshStartNeedsSync), true);
      expect(store.get(StoreKey.recoveryFreshStartLibraryReady), false);
      expect(await db.syncStreamRepository.getPendingTrashOperations(), isEmpty);
      for (final table in [
        'local_asset_entity',
        'local_album_entity',
        'trashed_local_asset_entity',
        'remote_asset_entity',
        'remote_album_entity',
      ]) {
        expect((await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle()).data['n'], 0);
      }
      for (final key in [SettingsKey.backupEnabled, SettingsKey.backupSyncAlbums]) {
        final row = await db.customSelect("SELECT value FROM settings WHERE key='${key.name}'").getSingle();
        expect(key.decode(row.data['value'] as String), false);
      }
    } finally {
      await store.dispose();
      await db.close();
    }
    expect(await recoveryFileHashes(source), before);
    expect(File('${source.path}-shm').existsSync(), true);
    await expectLater(operation.run(preparation, consent: true), throwsA(isA<RecoveryRefused>()));
  });

  test('unverifiable account offers login; no token or owner is guessed', () async {
    server.mode = 'unauthorized';
    final operation = FreshSqliteStart(host);
    final preparation = (await operation.prepare())!;
    expect(preparation.needsLogin, true);
    await operation.run(preparation, consent: true);
    final db = sqlite3.open(host.recovery.selected.path, mode: OpenMode.readOnly);
    expect(db.select('SELECT * FROM store_entity WHERE id IN (2,11,12)'), isEmpty);
    db.close();
  });

  test('cancelled export does not create a fresh database or stop upload queues', () async {
    host.cancelExport = true;
    expect(await FreshSqliteStart(host).prepare(), isNull);
    expect(host.recovery.selected.path, source.path);
    expect(host.uploadsStopped, false);
  });

  test('disk full before clean candidate retains source and leaves uploads untouched', () async {
    final before = await recoveryFileHashes(source);
    final operation = FreshSqliteStart(host);
    final preparation = (await operation.prepare())!;
    host.recovery.space = 0;
    await expectLater(operation.run(preparation, consent: true), throwsA(isA<RecoveryRefused>()));
    expect(host.uploadsStopped, false);
    expect(host.recovery.selected.path, source.path);
    expect(await recoveryFileHashes(source), before);
  });

  test('candidate altered before promotion is rejected, original remains selected', () async {
    final before = await recoveryFileHashes(source);
    final operation = FreshSqliteStart(
      host,
      checkpoint: (step) async {
        if (step != 'before_promotion') {
          return;
        }
        final candidate = host.recovery.root
            .listSync(recursive: true)
            .whereType<File>()
            .singleWhere((f) => f.path.endsWith('/candidate/immich.sqlite'));
        final raw = sqlite3.open(candidate.path);
        try {
          raw.execute("UPDATE settings SET value='true' WHERE key='backupEnabled'");
        } finally {
          raw.close();
        }
      },
    );
    await expectLater(operation.run((await operation.prepare())!, consent: true), throwsA(anything));
    expect(host.recovery.selected.path, source.path);
    expect(await recoveryFileHashes(source), before);
  });

  for (final stop in ['uploads_stopped', 'candidate_ready', 'before_promotion']) {
    test('interrupted fresh start at $stop preserves source and can restart', () async {
      final before = await recoveryFileHashes(source);
      final operation = FreshSqliteStart(
        host,
        checkpoint: (step) async {
          if (step == stop) {
            throw const RecoveryRefused('synthetic_interruption');
          }
        },
      );
      final preparation = (await operation.prepare())!;
      await expectLater(operation.run(preparation, consent: true), throwsA(isA<RecoveryRefused>()));
      expect(host.recovery.selected.path, source.path);
      expect(await recoveryFileHashes(source), before);
      final restarted = FreshSqliteStart(host);
      await restarted.run((await restarted.prepare())!, consent: true);
      expect(host.recovery.selected.path, isNot(source.path));
      expect(await recoveryFileHashes(source), before);
    });
  }
}
