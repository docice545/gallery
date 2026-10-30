import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:sqlite3_connection_pool/sqlite3_connection_pool.dart';
import 'package:sqlite_async/sqlite_async.dart';

void main() {
  test('Drift.close closes owned sqlite_async and all update-pool references', () async {
    final directory = await Directory.systemTemp.createTemp('foto23-pool-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/immich.sqlite');
    final connection = SqliteDatabase.withFactory(ImmichSqliteOpenFactory(path: file.path));
    await connection.initialize();
    final updates = SqliteConnectionPool.open(name: file.path, openConnections: () => throw StateError('missing pool'));
    final db = Drift.sqlite(connection, updates);
    await db.customSelect('SELECT count(*) FROM settings').get();
    expect(File('${file.path}-wal').existsSync(), true);
    await db.close();
    await db.close(); // idempotent ownership release
    expect(connection.closed, true);
    // SQLite removes WAL/SHM only when its last connection closes. Drift's
    // adapter alone used to leave them behind, even after updatePool.close().
    expect(File('${file.path}-wal').existsSync(), false);
    expect(File('${file.path}-shm').existsSync(), false);
    expect(file.existsSync(), true);
  });
}
