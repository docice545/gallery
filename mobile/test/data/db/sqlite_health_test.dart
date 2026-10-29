import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';

void main() {
  test('captures database and WAL/SHM sidecars without changing source', () async {
    final source = await Directory.systemTemp.createTemp('foto-sqlite-source-');
    final output = await Directory.systemTemp.createTemp('foto-sqlite-snapshots-');
    addTearDown(() async {
      await source.delete(recursive: true);
      await output.delete(recursive: true);
    });

    final database = File('${source.path}/immich.sqlite')..writeAsStringSync('database-bytes');
    File('${database.path}-wal').writeAsStringSync('wal-bytes');
    File('${database.path}-shm').writeAsStringSync('shm-bytes');

    final snapshot = await captureSqliteRecoverySnapshot(
      database: database,
      outputDirectory: output,
      reason: 'quick_check failed',
      now: () => DateTime.utc(2026, 10, 29, 12),
    );

    expect(await File('${snapshot.directory.path}/immich.sqlite').readAsString(), 'database-bytes');
    expect(await File('${snapshot.directory.path}/immich.sqlite-wal').readAsString(), 'wal-bytes');
    expect(await File('${snapshot.directory.path}/immich.sqlite-shm').readAsString(), 'shm-bytes');
    expect(await database.readAsString(), 'database-bytes');
    expect(await File('${database.path}-wal').readAsString(), 'wal-bytes');
    expect(await File('${database.path}-shm').readAsString(), 'shm-bytes');
    expect(snapshot.files, hasLength(3));
    expect(await snapshot.manifest.readAsString(), contains('quick_check failed'));
  });

  test('omits absent sidecars and refuses a missing primary database', () async {
    final source = await Directory.systemTemp.createTemp('foto-sqlite-source-');
    final output = await Directory.systemTemp.createTemp('foto-sqlite-snapshots-');
    addTearDown(() async {
      await source.delete(recursive: true);
      await output.delete(recursive: true);
    });

    final database = File('${source.path}/immich.sqlite')..writeAsStringSync('database-bytes');
    final snapshot = await captureSqliteRecoverySnapshot(database: database, outputDirectory: output);
    expect(snapshot.files, hasLength(1));
    expect(File('${snapshot.directory.path}/immich.sqlite-wal').existsSync(), isFalse);

    expect(
      () => captureSqliteRecoverySnapshot(
        database: File('${source.path}/missing.sqlite'),
        outputDirectory: output,
      ),
      throwsA(isA<SqliteRecoveryCaptureException>()),
    );
  });
}
