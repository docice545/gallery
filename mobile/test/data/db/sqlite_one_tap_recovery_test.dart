import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:sqlite3/sqlite3.dart';

/// A real-file platform harness. Native atomic selection/admission/fsync are
/// separately exercised by RecoveryStoreTest and Android instrumentation.
class FileRecoveryHost implements RecoveryHost {
  final File source;
  final Directory root;
  int space = 1 << 40;
  bool blocked = false;
  File? candidate;
  FileRecoveryHost(this.source, this.root);
  File get selection => File('${root.path}/selection');
  File get selected => selection.existsSync() ? File(selection.readAsStringSync()) : source;
  @override
  Future<({File source, Directory root, String token})> begin() async {
    blocked = true;
    await root.create(recursive: true);
    return (source: selected, root: root, token: 'test-owner');
  }

  @override
  Future<int> availableBytes() async => space;
  @override
  Future<void> sync(Directory directory) async {
    await for (final file in directory.list(recursive: true)) {
      if (file is File) {
        final handle = await file.open(mode: FileMode.append);
        await handle.flush();
        await handle.close();
      }
    }
  }

  @override
  Future<void> finish(String token) async {}
  @override
  Future<void> promote(String token, File file, String hash) async {
    expect(await recoveryFileHash(file), hash);
    candidate = file;
    final next = File('${selection.path}.next');
    await next.writeAsString(file.path, flush: true);
    await next.rename(selection.path);
    blocked = false;
  }
}

/// Empty the leaf index page without touching the table. This produces EXACTLY
/// the Samsung wrong-entry-count diagnostic, plus missing-row index diagnostics.
Future<void> corruptAlbumIndex(File file) async {
  final db = sqlite3.open(file.path);
  final pageSize = db.select('PRAGMA page_size').single.values.single! as int;
  final root =
      db.select("SELECT rootpage FROM sqlite_master WHERE name='idx_trashed_local_asset_album'").single.values.single!
          as int;
  db.close();
  final bytes = await file.readAsBytes();
  final offset = (root - 1) * pageSize;
  expect(bytes[offset], 10); // leaf index b-tree, never a data page
  bytes.fillRange(offset, offset + pageSize, 0);
  final page = ByteData.sublistView(bytes, offset, offset + pageSize);
  page.setUint8(0, 10);
  page.setUint16(5, pageSize == 65536 ? 0 : pageSize);
  await file.writeAsBytes(bytes, flush: true);
}

Future<File> createRecoveryFixture(Directory directory, {bool wal = true}) async {
  final live = File('${directory.path}/live.sqlite');
  var db = sqlite3.open(live.path);
  db.execute('CREATE TABLE trashed_local_asset_entity(id TEXT PRIMARY KEY, album_id TEXT NOT NULL)');
  db.execute('CREATE INDEX idx_trashed_local_asset_album ON trashed_local_asset_entity(album_id)');
  db.execute("INSERT INTO trashed_local_asset_entity VALUES ('photo-1','album-1'),('photo-2','album-2')");
  db.execute('CREATE TABLE pending_upload(id TEXT PRIMARY KEY)');
  db.execute('CREATE TABLE pending_delete(id TEXT PRIMARY KEY, acknowledged INTEGER NOT NULL)');
  db.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
  db.execute(
    "INSERT INTO settings VALUES ('account','existing-owner'),('cursor','confirmed-42'),('album','local-only')",
  );
  db.close();
  await corruptAlbumIndex(live);
  db = sqlite3.open(live.path);
  expect(
    db.select('PRAGMA integrity_check').map((r) => r.values.single),
    contains('wrong # of entries in index idx_trashed_local_asset_album'),
  );
  if (wal) {
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA wal_autocheckpoint=0');
  }
  db.execute("INSERT INTO pending_upload VALUES ('upload-wal-only')");
  db.execute("INSERT INTO pending_delete VALUES ('delete-wal-only',0),('already-confirmed',1)");
  final source = File('${directory.path}/immich.sqlite');
  for (final suffix in ['', '-wal', '-shm']) {
    final file = File('${live.path}$suffix');
    if (file.existsSync()) {
      await file.copy('${source.path}$suffix');
    }
  }
  db.close(); // No connection, including a WAL keeper, owns the test source.
  return source;
}

void main() {
  late Directory directory;
  late File source;
  late FileRecoveryHost host;
  late Map<String, String> before;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('foto23-');
    source = await createRecoveryFixture(directory);
    host = FileRecoveryHost(source, Directory('${directory.path}/recovery'));
    before = await recoveryFileHashes(source);
  });
  tearDown(() => directory.delete(recursive: true));

  test('startup read-only detection leaves committed primary and WAL bytes intact', () async {
    final probe = sqlite3.open(source.path, mode: OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA integrity_check(1)').single.values.single, isNot('ok'));
    } finally {
      probe.close();
    }
    final after = await recoveryFileHashes(source);
    expect(after[''], before['']);
    expect(after['-wal'], before['-wal']);
    await OneTapSqliteRecovery(host).run();
    expect(host.selected.path, isNot(source.path));
  });
  test('one tap preserves every table, WAL-only queues, account and confirmed cursor', () async {
    await OneTapSqliteRecovery(host).run();
    expect(host.blocked, false);
    expect(host.selected.path, isNot(source.path));
    final db = sqlite3.open(host.selected.path, mode: OpenMode.readOnly);
    try {
      expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
      expect(db.select('PRAGMA foreign_key_check'), isEmpty);
      expect(db.select('SELECT * FROM trashed_local_asset_entity'), hasLength(2));
      expect(db.select('SELECT id FROM pending_upload').single.values.single, 'upload-wal-only');
      expect(db.select('SELECT * FROM pending_delete ORDER BY acknowledged').map((r) => r.values.toList()).toList(), [
        ['delete-wal-only', 0],
        ['already-confirmed', 1],
      ]);
      expect(db.select("SELECT value FROM settings WHERE key='account'").single.values.single, 'existing-owner');
      expect(db.select("SELECT value FROM settings WHERE key='cursor'").single.values.single, 'confirmed-42');
    } finally {
      db.close();
    }
    expect(await recoveryFileHashes(source), before);
    final freshProcess = FileRecoveryHost(source, host.root);
    expect(freshProcess.selected.path, host.selected.path);
    final receiptFile = host.root
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('recovery-report.json'));
    final receipt = jsonDecode(await receiptFile.readAsString()) as Map;
    expect(receipt['contentMatch'], true);
    expect(receipt['tablesChecked'], greaterThanOrEqualTo(4));
    expect(await receiptFile.readAsString(), isNot(contains('existing-owner')));
  });

  for (final step in [
    'before_copy',
    'copy:immich.sqlite',
    'copied',
    'backup_durable',
    'before_reindex',
    'after_reindex',
    'before_promotion',
  ]) {
    test('interruption at $step preserves original; fresh attempt can recover', () async {
      await expectLater(
        OneTapSqliteRecovery(
          host,
          checkpoint: (at) async {
            if (at == step) {
              throw StateError('simulated process interruption');
            }
          },
        ).run(),
        throwsA(anything),
      );
      expect(host.selected.path, source.path);
      expect(await recoveryFileHashes(source), before);
      final fresh = FileRecoveryHost(source, host.root);
      await OneTapSqliteRecovery(fresh).run();
      expect(fresh.selected.path, isNot(source.path));
      expect(await recoveryFileHashes(source), before);
    });
  }
  test('a completed coordinator cannot halt the healthy promoted generation again', () async {
    final recovery = OneTapSqliteRecovery(host);
    await recovery.run();
    final selected = host.selected.path;
    await expectLater(
      recovery.run(),
      throwsA(isA<RecoveryRefused>().having((e) => e.reason, 'reason', 'already_committed')),
    );
    expect(host.blocked, false);
    expect(host.selected.path, selected);
    expect(await recoveryFileHashes(source), before);
  });
  test('insufficient storage refuses before creating a backup', () async {
    host.space = 1;
    await expectLater(
      OneTapSqliteRecovery(host).run(),
      throwsA(isA<RecoveryRefused>().having((e) => e.reason, 'reason', 'insufficient_space')),
    );
    expect(host.selected.path, source.path);
    expect(await recoveryFileHashes(source), before);
  });
  for (final fault in ['absent', 'truncated', 'checksum', 'whole-transaction', 'missing-shm']) {
    test('refuses $fault WAL without losing source evidence', () async {
      final wal = File('${source.path}-wal');
      if (fault == 'absent') {
        await wal.delete();
      } else if (fault == 'missing-shm') {
        await File('${source.path}-shm').delete();
      } else {
        var bytes = await wal.readAsBytes();
        if (fault == 'checksum') {
          bytes[24] ^= 255;
        }
        if (fault == 'whole-transaction') {
          final pageSize = ByteData.sublistView(bytes).getUint32(8);
          // Remove a whole final transaction, leaving a valid CRC commit prefix.
          var offset = bytes.length - (24 + pageSize);
          while (offset > 32 && ByteData.sublistView(bytes).getUint32(offset - (24 + pageSize) + 4) == 0) {
            offset -= 24 + pageSize;
          }
          bytes = bytes.sublist(0, offset);
        }
        await wal.writeAsBytes(fault == 'truncated' ? bytes.sublist(0, bytes.length - 1) : bytes, flush: true);
      }
      final damaged = await recoveryFileHashes(source);
      await expectLater(OneTapSqliteRecovery(host).run(), throwsA(anything));
      expect(host.selected.path, source.path);
      expect(await recoveryFileHashes(source), damaged);
    });
  }
  test('corrupt data page refuses even with the target index error', () async {
    final bytes = await source.readAsBytes();
    bytes[4096] = 0xff; // page 2: trashed_local_asset_entity data root
    await source.writeAsBytes(bytes, flush: true);
    final damaged = await recoveryFileHashes(source);
    await expectLater(OneTapSqliteRecovery(host).run(), throwsA(anything));
    expect(host.selected.path, source.path);
    expect(await recoveryFileHashes(source), damaged);
  });
  test('independent validation catches candidate edits after repair', () async {
    await expectLater(
      OneTapSqliteRecovery(
        host,
        checkpoint: (step) async {
          if (step == 'before_promotion') {
            final candidate = host.root
                .listSync(recursive: true)
                .whereType<File>()
                .firstWhere((f) => f.path.contains('sqlite-candidate-') && f.path.endsWith('immich.sqlite'));
            final db = sqlite3.open(candidate.path);
            db.execute('DELETE FROM pending_upload');
            db.close();
          }
        },
      ).run(),
      throwsA(anything),
    );
    expect(host.selected.path, source.path);
    expect(await recoveryFileHashes(source), before);
  });
}
