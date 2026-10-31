import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_cloud_reader.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:sqlite3_connection_pool/sqlite3_connection_pool.dart';
import 'package:sqlite_async/sqlite_async.dart';

void main() {
  late Directory directory;
  late File file;
  late SqliteDatabase connection;
  late Drift db;
  late SqliteCloudReader reader;
  setUp(() async {
    SqliteRecoveryGate.clearAfterValidatedRecovery();
    directory = await Directory.systemTemp.createTemp('foto24-cloud-pool-');
    file = File('${directory.path}/immich.sqlite');
    connection = SqliteDatabase.withFactory(
      ImmichSqliteOpenFactory(path: file.path, sqliteOptions: const SqliteOptions(maxReaders: 1)),
    );
    await connection.initialize();
    final updates = SqliteConnectionPool.open(name: file.path, openConnections: () => throw StateError('missing pool'));
    db = Drift.sqlite(connection, updates);
    await db.customSelect('SELECT COUNT(*) FROM settings').get();
    reader = SqliteCloudReader(connection, schemaVersion: db.schemaVersion);
    await connection.execute('CREATE TABLE cloud_regression(id INTEGER PRIMARY KEY, value INTEGER NOT NULL)');
    await connection.execute('INSERT INTO cloud_regression VALUES(1,0),(2,0)');
  });
  tearDown(() async {
    await reader.close();
    await db.close();
    SqliteRecoveryGate.clearAfterValidatedRecovery();
    await directory.delete(recursive: true);
  });
  Map<String, Object?> query(String sql) => {'operation': 'query', 'sql': sql, 'args': <Object?>[]};

  test('current production schema, concurrent writer/native client, and WAL-only commits share one pool', () async {
    expect(db.schemaVersion, 39); // Build 23's native reader hard-coded 38.
    await Future.wait([
      () async {
        for (var n = 1; n <= 80; n++) {
          await connection.writeTransaction((tx) async {
            await tx.execute('UPDATE cloud_regression SET value=? WHERE id=1', [n]);
            await tx.execute('UPDATE cloud_regression SET value=? WHERE id=2', [n]);
          });
        }
      }(),
      () async {
        for (var n = 0; n < 80; n++) {
          final result = (await reader.read(query('SELECT COUNT(DISTINCT value) AS n FROM cloud_regression')))! as Map;
          expect(result['rows'], [
            [1],
          ]);
        }
      }(),
    ]);
    expect(((await reader.read(query('SELECT value FROM cloud_regression WHERE id=1')))! as Map)['rows'], [
      [80],
    ]);
    expect(File('${file.path}-wal').existsSync(), true);
    await reader.close();
    expect(connection.closed, false);
    expect(File('${file.path}-wal').existsSync(), true);
    await connection.execute('UPDATE cloud_regression SET value=81');
    expect((await connection.get('PRAGMA integrity_check'))['integrity_check'], 'ok');
    expect(await connection.getAll('PRAGMA foreign_key_check'), isEmpty);
  });

  test('closing a native client drains a pending read without closing the owning Flutter pool', () async {
    final held = Completer<void>();
    final release = Completer<void>();
    final transaction = connection.readTransaction((tx) async {
      held.complete();
      await release.future;
    });
    await held.future;
    final pending = reader.read(query('SELECT value FROM cloud_regression WHERE id=1'));
    var drained = false;
    final close = reader.close().then((_) => drained = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(drained, false);
    expect(() => reader.read(query('SELECT 1')), throwsA(isA<PlatformException>()));
    release.complete();
    await transaction;
    expect(((await pending)! as Map)['rows'], [
      [0],
    ]);
    await close;
    expect(drained, true);
    expect(connection.closed, false);
  });

  test('owning pool checkpoints WAL while the native client keeps the same admitted generation', () async {
    await connection.execute('UPDATE cloud_regression SET value=42');
    expect(File('${file.path}-wal').lengthSync(), greaterThan(32));
    final before = await reader.read(query('SELECT id,value FROM cloud_regression ORDER BY id'));
    final checkpoint = await connection.writeLock(
      (tx) => tx.computeWithDatabase((db) async => db.select('PRAGMA wal_checkpoint(TRUNCATE)').single.values.toList()),
    );
    expect(checkpoint.first, 0);
    expect(File('${file.path}-wal').lengthSync(), 0);
    expect(await reader.read(query('SELECT id,value FROM cloud_regression ORDER BY id')), before);
    await connection.execute('UPDATE cloud_regression SET value=43');
    expect(((await reader.read(query('SELECT value FROM cloud_regression WHERE id=1')))! as Map)['rows'], [
      [43],
    ]);
    expect((await connection.get('PRAGMA integrity_check'))['integrity_check'], 'ok');
  });

  test('native requests cannot write, checkpoint, attach, reset schema or add a trailing statement', () async {
    for (final sql in [
      'DELETE FROM cloud_regression RETURNING id',
      'PRAGMA wal_checkpoint(TRUNCATE)',
      "ATTACH ':memory:' AS other",
      'PRAGMA writable_schema=ON',
      'SELECT 1; DELETE FROM cloud_regression',
      'WITH x AS (SELECT 1) DELETE FROM cloud_regression RETURNING id',
    ]) {
      await expectLater(reader.read(query(sql)), throwsA(anything));
    }
    expect((await connection.get('SELECT COUNT(*) AS n FROM cloud_regression'))['n'], 2);
    final tooMany = query('WITH RECURSIVE x(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM x WHERE n<202) SELECT n FROM x');
    await expectLater(reader.read(tooMany), throwsA(isA<FormatException>()));
  });

  test('digest is streamed in one snapshot; recovery gate blocks every later native request', () async {
    final request = <String, Object?>{
      'operation': 'digest',
      'scope': 'synthetic-owner',
      'queries': [
        {'sql': 'SELECT * FROM cloud_regression ORDER BY id', 'args': <Object?>[]},
      ],
    };
    final digest = await reader.read(request);
    expect(digest, matches(RegExp('^[0-9a-f]{64}\$')));
    expect(await reader.read(request), digest);
    await connection.execute('UPDATE cloud_regression SET value=2');
    expect(await reader.read(request), isNot(digest));
    SqliteRecoveryGate.markRequired(check: 'synthetic-index-failure', resultCode: 779);
    expect(() => reader.read(request), throwsA(isA<SqliteDatabaseUnhealthy>()));
    await reader.close();
    final reopenedClient = SqliteCloudReader(connection, schemaVersion: db.schemaVersion);
    expect(() => reopenedClient.read(query('SELECT 1')), throwsA(isA<SqliteDatabaseUnhealthy>()));
    await reopenedClient.close();
  });
}
