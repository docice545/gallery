import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fixtures/sqlite_checkpoint_fixture.dart';
import 'sqlite_one_tap_recovery_test.dart' show FileRecoveryHost, createRecoveryFixture;

const samsungEmptyShmHash = 'fd4c9fda9cd3f9ae7c962b0ddf37232294d55580e1aa165aa06129b8549389eb';

void main() {
  late Directory directory;
  setUp(() async => directory = await Directory.systemTemp.createTemp('foto24-checkpoint-'));
  tearDown(() => directory.delete(recursive: true));

  test('stale retained checkpoint SHM plus an older full snapshot cannot authorize lost later commits', () async {
    final source = await createCheckpointFixture(directory, loseLaterCommit: true);
    final before = await recoveryFileHashes(source);
    final host = FileRecoveryHost(source, Directory('${source.parent.path}/recovery'));
    await expectLater(
      OneTapSqliteRecovery(host).run(),
      throwsA(isA<RecoveryRefused>().having((e) => e.reason, 'reason', 'checkpoint_history_not_terminal')),
    );
    expect(host.selected.path, source.path);
    expect(await recoveryFileHashes(source), before);
  });

  test('completed checkpoint is diagnosed but a historical witness cannot prove it was the last commit', () async {
    final source = await createCheckpointFixture(directory);
    expect(File('${source.path}-wal').lengthSync(), 0);
    final before = await recoveryFileHashes(source);
    final probe = openSqliteStartupProbe(source);
    expect(
      probe.select('PRAGMA integrity_check').map((r) => r.values.single),
      contains('wrong # of entries in index idx_trashed_local_asset_album'),
    );
    probe.close();
    expect(await recoveryFileHashes(source), before);
    final host = FileRecoveryHost(source, Directory('${source.parent.path}/recovery'));
    await expectLater(
      OneTapSqliteRecovery(host).run(),
      throwsA(isA<RecoveryRefused>().having((e) => e.reason, 'reason', 'checkpoint_history_not_terminal')),
    );
    expect(host.selected.path, source.path);
    final db = openSqliteStartupProbe(source);
    expect(db.select('SELECT id FROM pending_upload').single.values.single, 'upload-wal-only');
    expect(db.select('SELECT * FROM pending_delete'), hasLength(2));
    db.close();
    expect(await recoveryFileHashes(source), before);
    final receipt = host.root
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('/recovery-report.json'));
    final report = jsonDecode(receipt.readAsStringSync());
    expect(report['walEvidence']['code'], 'checkpoint_history_not_terminal');
    expect(report['walEvidence']['complete'], false);
    expect(report['integrityStatus'], 'passed'); // Candidate only, never promoted.
    expect(report['contentMatch'], true);
  });

  for (final lost in [false, true]) {
    test(
      'Build 23 read-only probe produces Samsung SHM after ${lost ? 'WAL loss' : 'clean checkpoint'}; no promotion',
      () async {
        final File source;
        if (lost) {
          source = await createRecoveryFixture(directory);
          await File('${source.path}-wal').writeAsBytes([], flush: true);
        } else {
          source = await createCheckpointFixture(directory);
        }
        // This is the Build 23 startup open. SQLite rebuilds SHM even in read-only mode.
        final legacy = sqlite3.open(source.path, mode: OpenMode.readOnly);
        legacy.select('PRAGMA integrity_check(1)');
        legacy.close();
        expect(await recoveryFileHash(File('${source.path}-shm')), samsungEmptyShmHash);
        final before = await recoveryFileHashes(source);
        final host = FileRecoveryHost(source, Directory('${source.parent.path}/recovery'));
        await expectLater(
          OneTapSqliteRecovery(host).run(),
          throwsA(isA<RecoveryRefused>().having((e) => e.reason, 'reason', 'empty_wal_evidence_missing')),
        );
        expect(host.selected.path, source.path);
        expect(await recoveryFileHashes(source), before);
        final report = jsonDecode(
          host.root
              .listSync(recursive: true)
              .whereType<File>()
              .singleWhere((f) => f.path.endsWith('/recovery-report.json'))
              .readAsStringSync(),
        );
        expect(report['tablesChecked'], 4);
        expect(report['integrityStatus'], 'passed'); // Index repaired on a copy, but WAL proof missing.
        expect(report['walEvidence']['complete'], false);
      },
    );
  }

  test('a coherent checkpoint header alone is insufficient without a full retained snapshot', () async {
    final source = await createCheckpointFixture(directory, witness: false);
    final host = FileRecoveryHost(source, Directory('${source.parent.path}/recovery'));
    await expectLater(
      OneTapSqliteRecovery(host).run(),
      throwsA(isA<RecoveryRefused>().having((e) => e.reason, 'reason', 'checkpoint_witness_missing')),
    );
    expect(host.selected.path, source.path);
  });

  test('an older snapshot cannot replace newer checkpointed table contents', () async {
    final source = await createCheckpointFixture(directory);
    final bytes = await source.readAsBytes();
    final marker = utf8.encode('confirmed-42');
    final offset = bytes.indexOf(marker.first);
    // Locate the complete marker, without opening SQLite and rebuilding SHM.
    final position = [
      for (var i = offset; i <= bytes.length - marker.length; i++)
        if (marker.indexed.every((e) => bytes[i + e.$1] == e.$2)) i,
    ].single;
    bytes[position + marker.length - 1] = '3'.codeUnitAt(0);
    await source.writeAsBytes(bytes, flush: true);
    final host = FileRecoveryHost(source, Directory('${source.parent.path}/recovery'));
    await expectLater(OneTapSqliteRecovery(host).run(), throwsA(isA<RecoveryRefused>()));
    expect(host.selected.path, source.path);
  });

  for (final stop in ['copy:immich.sqlite', 'backup_durable', 'after_reindex']) {
    test('checkpoint diagnosis interrupted at $stop preserves evidence and remains blocked on retry', () async {
      final source = await createCheckpointFixture(directory);
      final before = await recoveryFileHashes(source);
      final host = FileRecoveryHost(source, Directory('${source.parent.path}/recovery'));
      await expectLater(
        OneTapSqliteRecovery(
          host,
          checkpoint: (step) async {
            if (step == stop) {
              throw const RecoveryRefused('synthetic_interruption');
            }
          },
        ).run(),
        throwsA(stop.startsWith('copy:') ? isA<SqliteRecoveryCaptureException>() : isA<RecoveryRefused>()),
      );
      expect(host.selected.path, source.path);
      expect(await recoveryFileHashes(source), before);
      await expectLater(
        OneTapSqliteRecovery(FileRecoveryHost(source, host.root)).run(),
        throwsA(isA<RecoveryRefused>().having((e) => e.reason, 'reason', 'checkpoint_history_not_terminal')),
      );
      expect(host.selected.path, source.path);
      expect(await recoveryFileHashes(source), before);
    });
  }
}
