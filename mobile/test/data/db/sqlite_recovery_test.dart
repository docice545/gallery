import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_recovery.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('keeps a healthy snapshot read-only and emits no candidate', () async {
    final source = await Directory.systemTemp.createTemp('foto-recovery-source-');
    final output = await Directory.systemTemp.createTemp('foto-recovery-output-');
    addTearDown(() async {
      await source.delete(recursive: true);
      await output.delete(recursive: true);
    });

    final database = File('${source.path}/immich.sqlite');
    final db = sqlite3.open(database.path);
    db.execute('CREATE TABLE pending_upload (id TEXT PRIMARY KEY, path TEXT NOT NULL)');
    db.execute("INSERT INTO pending_upload VALUES ('local-1', '/safe/local.jpg')");
    db.close();

    final snapshot = await captureSqliteRecoverySnapshot(database: database, outputDirectory: output);
    final report = await diagnoseAndRepairSqliteSnapshot(snapshot: snapshot.directory, outputDirectory: output);

    expect(report.status, SqliteRecoveryStatus.healthy);
    expect(report.candidate, isNull);
    expect(report.toJson()['promotionAllowed'], isFalse);
    expect(database.existsSync(), isTrue);
    final reopened = sqlite3.open(database.path);
    expect(reopened.select('SELECT path FROM pending_upload').single.values.single, '/safe/local.jpg');
    reopened.close();
  });

  test('repairs only a corrupt index on a copy and preserves pending rows', () async {
    final source = await Directory.systemTemp.createTemp('foto-recovery-index-source-');
    final output = await Directory.systemTemp.createTemp('foto-recovery-index-output-');
    addTearDown(() async {
      await source.delete(recursive: true);
      await output.delete(recursive: true);
    });

    final database = File('${source.path}/immich.sqlite');
    final db = sqlite3.open(database.path);
    db.execute('CREATE TABLE remote_asset_entity (id TEXT PRIMARY KEY, checksum TEXT NOT NULL)');
    db.execute('CREATE TABLE pending_delete (id TEXT PRIMARY KEY)');
    // A unique index makes the write path validate the damaged b-tree and
    // reproduce SQLITE_CORRUPT_INDEX (779), matching updateAssetsV2's
    // remote_asset_entity failure mode.
    db.execute('CREATE UNIQUE INDEX remote_asset_checksum ON remote_asset_entity(checksum)');
    for (var index = 1; index <= 100; index++) {
      final suffix = index.toString().padLeft(3, '0');
      db.execute("INSERT INTO remote_asset_entity VALUES ('asset-$index', 'checksum-$suffix')");
    }
    db.execute("INSERT INTO pending_delete VALUES ('asset-1')");
    final pageSize = db.select('PRAGMA page_size').single.values.single! as int;
    final indexRoot =
        db.select("SELECT rootpage FROM sqlite_master WHERE name = 'remote_asset_checksum'").single.values.single!
            as int;
    db.close();

    // Change the serial-type byte in one index cell. SQLite's integrity check
    // reports a named index failure while the table and pending-delete rows
    // stay readable; a write that updates remote_asset_entity reproduces the
    // extended SQLITE_CORRUPT_INDEX result, and REINDEX can safely rebuild
    // that index on a copy.
    final bytes = await database.readAsBytes();
    final pageOffset = (indexRoot - 1) * pageSize;
    final header = ByteData.sublistView(bytes, pageOffset, pageOffset + pageSize);
    final cellCount = header.getUint16(3, Endian.big);
    final cellContentOffset = header.getUint16(5, Endian.big);
    expect(cellCount, greaterThan(1));
    expect(cellContentOffset + 5, lessThan(pageSize));
    header.setUint8(cellContentOffset + 5, 0);
    await database.writeAsBytes(bytes, flush: true);
    final corruptedBytes = await database.readAsBytes();

    final probe = sqlite3.open(database.path);
    expect(
      () => probe.execute("UPDATE remote_asset_entity SET checksum = 'checksum-new' WHERE id = 'asset-1'"),
      throwsA(isA<SqliteException>().having((error) => error.extendedResultCode, 'extendedResultCode', 779)),
    );
    probe.close();

    // The failed write must not alter the primary file or its pending rows.
    expect(await database.readAsBytes(), corruptedBytes);
    final pending = sqlite3.open(database.path);
    addTearDown(pending.close);
    pending.execute('PRAGMA journal_mode = WAL');
    pending.execute('PRAGMA wal_autocheckpoint = 0');
    pending.execute('CREATE TABLE pending_upload (id TEXT PRIMARY KEY)');
    pending.execute("INSERT INTO pending_upload VALUES ('upload-in-wal')");
    final before = await database.readAsBytes();
    final walBefore = await File('${database.path}-wal').readAsBytes();
    final snapshot = await captureSqliteRecoverySnapshot(database: database, outputDirectory: output);
    final report = await diagnoseAndRepairSqliteSnapshot(snapshot: snapshot.directory, outputDirectory: output);

    expect(report.status, SqliteRecoveryStatus.repairedIndex);
    expect(report.candidate, isNotNull);
    expect(report.candidateIntegrity, 'ok');
    expect(report.candidateTableFingerprints, report.sourceTableFingerprints);
    expect(report.toJson()['promotionAllowed'], isFalse);
    expect(await database.readAsBytes(), before);
    expect(await File('${database.path}-wal').readAsBytes(), walBefore);

    final candidateDb = sqlite3.open('${report.candidate!.path}/immich.sqlite');
    expect(candidateDb.select('SELECT id FROM pending_upload').single.values.single, 'upload-in-wal');
    expect(candidateDb.select('SELECT id FROM pending_delete').single.values.single, 'asset-1');
    candidateDb.execute("INSERT INTO remote_asset_entity VALUES ('asset-after-recovery', 'checksum-after')");
    expect(
      candidateDb
          .select("SELECT checksum FROM remote_asset_entity WHERE id = 'asset-after-recovery'")
          .single
          .values
          .single,
      'checksum-after',
    );
    expect(candidateDb.select('SELECT id FROM pending_delete').single.values.single, 'asset-1');
    candidateDb.close();
  });

  test('refuses a malformed page instead of inventing a recovery', () async {
    final source = await Directory.systemTemp.createTemp('foto-recovery-malformed-source-');
    final output = await Directory.systemTemp.createTemp('foto-recovery-malformed-output-');
    addTearDown(() async {
      await source.delete(recursive: true);
      await output.delete(recursive: true);
    });

    final database = File('${source.path}/immich.sqlite')..writeAsStringSync('not-a-sqlite-database');
    final snapshot = await captureSqliteRecoverySnapshot(database: database, outputDirectory: output);
    final report = await diagnoseAndRepairSqliteSnapshot(snapshot: snapshot.directory, outputDirectory: output);

    expect(report.status, SqliteRecoveryStatus.requiresManualRecovery);
    expect(report.candidate, isNull);
    expect(report.toJson()['promotionAllowed'], isFalse);
    expect(await database.readAsString(), 'not-a-sqlite-database');
  });

  for (final omission in ['none', 'recorded', 'unrecorded', 'truncated', 'corrupt header', 'corrupt frame']) {
    test('preserves pending operations when diagnosing a WAL snapshot: $omission', () async {
      final root = await Directory.systemTemp.createTemp('foto-recovery-wal-');
      final database = File('${root.path}/immich.sqlite');
      final db = sqlite3.open(database.path);
      addTearDown(() async {
        db.close();
        await root.delete(recursive: true);
      });
      db.execute('CREATE TABLE pending_upload (id TEXT PRIMARY KEY)');
      db.execute('CREATE TABLE pending_delete (id TEXT PRIMARY KEY)');
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA wal_autocheckpoint = 0');
      db.execute("INSERT INTO pending_upload VALUES ('upload-in-wal')");
      db.execute("INSERT INTO pending_delete VALUES ('delete-in-wal')");
      final before = await database.readAsBytes();
      final walBefore = await File('${database.path}-wal').readAsBytes();
      final snapshot = await captureSqliteRecoverySnapshot(
        database: database,
        outputDirectory: Directory('${root.path}/snapshots'),
      );
      final snapshotWal = File('${snapshot.directory.path}/immich.sqlite-wal');
      if (omission == 'truncated') {
        await snapshotWal.writeAsBytes(walBefore.sublist(0, 32), flush: true);
      } else if (omission.startsWith('corrupt')) {
        final damaged = Uint8List.fromList(walBefore);
        damaged[omission == 'corrupt header' ? 24 : damaged.length - 1] ^= 1;
        await snapshotWal.writeAsBytes(damaged, flush: true);
      } else if (omission != 'none') {
        await snapshotWal.delete();
      }
      if (omission == 'recorded') {
        // Capture can retain partial evidence when a sidecar changes/disappears.
        // Such evidence must never be certified healthy or used for index repair.
        final manifest = jsonDecode(await snapshot.manifest.readAsString()) as Map<String, dynamic>;
        manifest['omittedSidecars'] = ['immich.sqlite-wal'];
        final files = manifest['files']! as List<dynamic>;
        files.removeWhere((dynamic file) => file['name'] == 'immich.sqlite-wal');
        await snapshot.manifest.writeAsString(jsonEncode(manifest));
      }

      final report = await diagnoseAndRepairSqliteSnapshot(
        snapshot: snapshot.directory,
        outputDirectory: Directory('${root.path}/diagnosis'),
      );

      expect(
        report.status,
        omission == 'none' ? SqliteRecoveryStatus.healthy : SqliteRecoveryStatus.requiresManualRecovery,
      );
      if (omission == 'none') {
        // The diagnostic fingerprints must include committed WAL-only rows.
        final copied = sqlite3.open('${snapshot.directory.path}/immich.sqlite', mode: OpenMode.readOnly);
        try {
          expect(copied.select('SELECT id FROM pending_upload').single.values.single, 'upload-in-wal');
          expect(copied.select('SELECT id FROM pending_delete').single.values.single, 'delete-in-wal');
        } finally {
          copied.close();
        }
        expect(report.sourceTableFingerprints, {
          'pending_upload': sha256.convert(utf8.encode('[["upload-in-wal"]]')).toString(),
          'pending_delete': sha256.convert(utf8.encode('[["delete-in-wal"]]')).toString(),
        });
      }
      expect(report.candidate, isNull);
      expect(report.toJson()['promotionAllowed'], isFalse);
      expect(await database.readAsBytes(), before);
      expect(await File('${database.path}-wal').readAsBytes(), walBefore);
      expect(db.select('SELECT id FROM pending_upload').single.values.single, 'upload-in-wal');
      expect(db.select('SELECT id FROM pending_delete').single.values.single, 'delete-in-wal');
    });
  }
}
