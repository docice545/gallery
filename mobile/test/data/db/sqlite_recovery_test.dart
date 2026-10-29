import 'dart:io';
import 'dart:typed_data';

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
    db.dispose();

    final snapshot = await captureSqliteRecoverySnapshot(database: database, outputDirectory: output);
    final report = await diagnoseAndRepairSqliteSnapshot(snapshot: snapshot.directory, outputDirectory: output);

    expect(report.status, SqliteRecoveryStatus.healthy);
    expect(report.candidate, isNull);
    expect(report.toJson()['promotionAllowed'], isFalse);
    expect(database.existsSync(), isTrue);
    final reopened = sqlite3.open(database.path);
    expect(reopened.select('SELECT path FROM pending_upload').single[0], '/safe/local.jpg');
    reopened.dispose();
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
    db.execute('CREATE INDEX remote_asset_checksum ON remote_asset_entity(checksum)');
    db.execute("INSERT INTO remote_asset_entity VALUES ('asset-1', 'checksum-1')");
    db.execute("INSERT INTO pending_delete VALUES ('asset-1')");
    final pageSize = db.select('PRAGMA page_size').single[0] as int;
    final indexRoot = db
        .select("SELECT rootpage FROM sqlite_master WHERE name = 'remote_asset_checksum'")
        .single[0] as int;
    db.dispose();

    // Remove one cell pointer from the index b-tree. SQLite's integrity check
    // reports a missing index entry while the table and pending-delete rows
    // stay readable; REINDEX can safely rebuild that index on a copy.
    final bytes = await database.readAsBytes();
    final pageOffset = (indexRoot - 1) * pageSize;
    final header = ByteData.sublistView(bytes, pageOffset, pageOffset + pageSize);
    final cellCount = header.getUint16(3, Endian.big);
    expect(cellCount, greaterThan(1));
    header.setUint16(3, cellCount - 1, Endian.big);
    await database.writeAsBytes(bytes, flush: true);

    final before = await database.readAsBytes();
    final snapshot = await captureSqliteRecoverySnapshot(database: database, outputDirectory: output);
    final report = await diagnoseAndRepairSqliteSnapshot(snapshot: snapshot.directory, outputDirectory: output);

    expect(report.status, SqliteRecoveryStatus.repairedIndex);
    expect(report.candidate, isNotNull);
    expect(report.candidateIntegrity, 'ok');
    expect(report.candidateTableFingerprints, report.sourceTableFingerprints);
    expect(report.toJson()['promotionAllowed'], isFalse);
    expect(await database.readAsBytes(), before);

    final candidateDb = sqlite3.open('${report.candidate!.path}/immich.sqlite');
    expect(candidateDb.select('SELECT id FROM pending_delete').single[0], 'asset-1');
    candidateDb.dispose();
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
}
