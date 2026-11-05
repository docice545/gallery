import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
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

  test('close drains active and queued readers/writers before releasing its final pool reference', () async {
    final directory = await Directory.systemTemp.createTemp('foto24-pool-drain-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/immich.sqlite');
    final connection = SqliteDatabase.withFactory(
      ImmichSqliteOpenFactory(path: file.path, sqliteOptions: const SqliteOptions(maxReaders: 1)),
    );
    await connection.initialize();
    final updates = SqliteConnectionPool.open(name: file.path, openConnections: () => throw StateError('missing pool'));
    final db = Drift.sqlite(connection, updates);
    await db.customStatement('CREATE TABLE drain_test(id INTEGER PRIMARY KEY)');
    final writerHeld = Completer<void>();
    final readerHeld = Completer<void>();
    final release = Completer<void>();
    final finished = <String>[];
    final writer = connection
        .writeTransaction((tx) async {
          await tx.execute('INSERT INTO drain_test VALUES (1)');
          writerHeld.complete();
          await release.future;
        })
        .whenComplete(() => finished.add('writer'));
    final reader = connection
        .readTransaction((tx) async {
          await tx.get('SELECT COUNT(*) FROM drain_test');
          readerHeld.complete();
          await release.future;
        })
        .whenComplete(() => finished.add('reader'));
    await Future.wait([writerHeld.future, readerHeld.future]).timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError('initial reader=${readerHeld.isCompleted}, writer=${writerHeld.isCompleted}'),
    );
    final queuedWrite = connection
        .execute('INSERT INTO drain_test VALUES (2)')
        .whenComplete(() => finished.add('queuedWrite'));
    final queuedRead = connection.get('SELECT COUNT(*) FROM drain_test').whenComplete(() => finished.add('queuedRead'));
    // Allow already admitted requests to enter the native pool queues.
    await Future<void>.delayed(Duration.zero);
    var closed = false;
    final close = db.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final closedBeforeDrain = closed;
    release.complete();
    expect(closedBeforeDrain, false);
    await Future.wait([writer, reader, queuedWrite, queuedRead, close]).timeout(
      const Duration(seconds: 5),
      onTimeout: () =>
          throw StateError('drain did not finish, connection.closed=${connection.closed}, finished=$finished'),
    );
    await expectLater(connection.execute('INSERT INTO drain_test VALUES (3)'), throwsStateError);
    expect(closed, true);
    expect(File('${file.path}-wal').existsSync(), false);
    expect(File('${file.path}-shm').existsSync(), false);
    final reopened = sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
    try {
      expect(reopened.select('SELECT id FROM drain_test ORDER BY id').map((r) => r['id']), [1, 2]);
      expect(reopened.select('PRAGMA integrity_check').single.values.single, 'ok');
    } finally {
      reopened.close();
    }
  });
}
