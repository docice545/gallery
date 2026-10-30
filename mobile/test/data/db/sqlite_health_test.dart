import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';

void main() {
  setUp(() {
    SqliteRecoveryGate.clearAfterValidatedRecovery();
  });

  tearDown(() {
    SqliteRecoveryGate.clearAfterValidatedRecovery();
  });

  test('classifies SQLite SQLITE_CORRUPT_INDEX 779 as unsafe corruption', () {
    expect(classifySqliteResultCode(779), SqliteHealthFailure.corrupt);
  });

  test('holds sync after SQLITE_CORRUPT_INDEX until validated recovery clears it', () {
    SqliteRecoveryGate.markRequired(check: 'updateAssetsV2[user]', resultCode: 779);

    expect(SqliteRecoveryGate.isHalted, isTrue);
    expect(SqliteRecoveryGate.check, 'updateAssetsV2[user]');
    expect(SqliteRecoveryGate.resultCode, 779);
    expect(
      () => SqliteRecoveryGate.throwIfRequired('remote sync'),
      throwsA(
        isA<SqliteDatabaseUnhealthy>().having(
          (error) => error.cause,
          'cause',
          779,
        ),
      ),
    );

    // Only the explicit, user-mediated recovery path may release the barrier.
    SqliteRecoveryGate.clearAfterValidatedRecovery();
    expect(SqliteRecoveryGate.isHalted, isFalse);
    expect(() => SqliteRecoveryGate.throwIfRequired('remote sync'), returnsNormally);
  });

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

    final second = await captureSqliteRecoverySnapshot(
      database: database,
      outputDirectory: output,
      now: () => DateTime.utc(2026, 10, 29, 12),
    );
    expect(second.directory.path, isNot(snapshot.directory.path));
    expect(snapshot.directory.existsSync(), isTrue);
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

    await expectLater(
      captureSqliteRecoverySnapshot(
        database: File('${source.path}/missing.sqlite'),
        outputDirectory: output,
      ),
      throwsA(isA<SqliteRecoveryCaptureException>()),
    );
  });
}
