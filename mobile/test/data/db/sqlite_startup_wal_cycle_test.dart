import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_async/sqlite_async.dart';

Future<File> snapshot(File live, Directory root) async {
  final directory = await root.createTemp('unclean-stop-');
  final source = File('${directory.path}/immich.sqlite');
  for (final suffix in ['', '-wal', '-shm']) {
    await File('${live.path}$suffix').copy('${source.path}$suffix');
  }
  return source;
}

Future<void> checkRestart(File live, Directory root, int count) async {
  // Snapshot an open writer after its commit, before last-connection cleanup.
  // This models an unclean stop; actual process force-stop is also tested on Android.
  final source = await snapshot(live, root);
  final before = await recoveryFileHashes(source);
  await validateStartupSqliteFiles(source);
  expect(await recoveryFileHashes(source), before);
  final probe = openSqliteStartupProbe(source);
  try {
    expect(probe.select('PRAGMA integrity_check').single.values.single, 'ok');
    expect(probe.select('SELECT COUNT(*) FROM photos').single.values.single, count);
    expect(probe.select('SELECT SUM(length(payload)) FROM photos').single.values.single, greaterThan(65536));
  } finally {
    probe.close();
  }
}

void main() {
  for (final automatic in [false, true]) {
    test('admitted writer survives repeated WAL reuse and restart, automatic checkpoint=$automatic', () async {
      final root = await Directory.systemTemp.createTemp('foto24-wal-reuse-');
      addTearDown(() => root.delete(recursive: true));
      final live = File('${root.path}/live.sqlite');
      final db = ImmichSqliteOpenFactory(
        path: live.path,
      ).openNativeConnection(const SqliteOpenOptions(primaryConnection: true, readOnly: false));
      try {
        db.execute('PRAGMA wal_autocheckpoint=${automatic ? 2 : 0}');
        db.execute('CREATE TABLE photos(id INTEGER PRIMARY KEY, payload BLOB)');
        db.execute('INSERT INTO photos(payload) VALUES (randomblob(65536))');
        for (var cycle = 0; cycle < 5; cycle++) {
          if (!automatic) {
            expect(db.select('PRAGMA wal_checkpoint(PASSIVE)').single.values.first, 0);
          }
          db.execute('INSERT INTO photos(payload) VALUES (randomblob(?))', [cycle.isEven ? 1 : 8192]);
          await checkRestart(live, root, cycle + 2);
        }
      } finally {
        db.close();
      }
    });
  }

  test('journal sizing never discards commits or a reader pinned across checkpoint', () async {
    final root = await Directory.systemTemp.createTemp('foto24-pinned-wal-');
    addTearDown(() => root.delete(recursive: true));
    final live = File('${root.path}/live.sqlite');
    final db = ImmichSqliteOpenFactory(
      path: live.path,
    ).openNativeConnection(const SqliteOpenOptions(primaryConnection: true, readOnly: false));
    Database? reader;
    try {
      db.execute('PRAGMA wal_autocheckpoint=0');
      db.execute('CREATE TABLE photos(id INTEGER PRIMARY KEY, payload BLOB)');
      db.execute('INSERT INTO photos(payload) VALUES (randomblob(65536))');
      reader = sqlite3.open(live.path, mode: OpenMode.readOnly)..execute('BEGIN');
      expect(reader.select('SELECT COUNT(*) FROM photos').single.values.single, 1);
      db.execute('INSERT INTO photos(payload) VALUES (randomblob(32768))');
      final checkpoint = db.select('PRAGMA wal_checkpoint(PASSIVE)').single.values.toList();
      expect(checkpoint[2]! as int, lessThan(checkpoint[1]! as int));
      expect(reader.select('SELECT COUNT(*) FROM photos').single.values.single, 1);
      await checkRestart(live, root, 2);
      reader.execute('COMMIT');
      reader.close();
      reader = null;
      expect(db.select('PRAGMA wal_checkpoint(PASSIVE)').single.values.first, 0);
      db.execute('INSERT INTO photos(payload) VALUES (randomblob(1))');
      await checkRestart(live, root, 3);
    } finally {
      reader?.close();
      db.close();
    }
  });

  test('unknown legacy recycled tails remain blocked and byte-for-byte retained', () async {
    final root = await Directory.systemTemp.createTemp('foto24-old-wal-');
    addTearDown(() => root.delete(recursive: true));
    final live = File('${root.path}/live.sqlite');
    final db = sqlite3.open(live.path);
    try {
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA wal_autocheckpoint=0');
      db.execute('CREATE TABLE photos(id INTEGER PRIMARY KEY, payload BLOB)');
      db.execute('INSERT INTO photos(payload) VALUES (randomblob(65536))');
      db.execute('PRAGMA wal_checkpoint(PASSIVE)');
      db.execute('INSERT INTO photos(payload) VALUES (randomblob(1))');
      final source = await snapshot(live, root);
      final before = await recoveryFileHashes(source);
      await expectLater(validateStartupSqliteFiles(source), throwsA(isA<FormatException>()));
      expect(await recoveryFileHashes(source), before);
    } finally {
      db.close();
    }
  });
}
