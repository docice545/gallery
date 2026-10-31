import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_platform.dart';
import 'package:immich_mobile/data/db/sqlite_wal_evidence.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Platform boundary: admission, capacity, fsync and atomic selection. Tests use
/// real SQLite files and a durable file selector, never mocked SQLite results.
abstract interface class RecoveryHost {
  Future<({File source, Directory root, String token})> begin();
  Future<int> availableBytes();
  Future<void> sync(Directory directory);
  Future<void> promote(String token, File candidate, String hash);
  Future<void> finish(String token);
  Future<List<Directory>> historyRoots();
}

final class AndroidRecoveryHost implements RecoveryHost {
  const AndroidRecoveryHost();
  @override
  Future<({File source, Directory root, String token})> begin() async {
    // lock() in main requests worker cancellation. Leases are released only
    // after the corresponding Drift, sqlite_async AND pool handles close.
    for (var attempt = 0; ; attempt++) {
      try {
        final value = (await SqliteRecoveryPlatform.channel.invokeMapMethod<String, String>('begin'))!;
        return (source: File(value['source']!), root: Directory(value['root']!), token: value['token']!);
      } catch (_) {
        if (attempt >= 120) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  @override
  Future<int> availableBytes() async => (await SqliteRecoveryPlatform.channel.invokeMethod<int>('space'))!;
  @override
  Future<void> sync(Directory directory) =>
      SqliteRecoveryPlatform.channel.invokeMethod('sync', {'path': directory.path});
  @override
  Future<void> promote(String token, File candidate, String hash) =>
      SqliteRecoveryPlatform.channel.invokeMethod('promote', {'token': token, 'path': candidate.path, 'hash': hash});
  @override
  Future<void> finish(String token) => SqliteRecoveryPlatform.channel.invokeMethod('finish', {'token': token});
  @override
  Future<List<Directory>> historyRoots() async => [
    for (final path in (await SqliteRecoveryPlatform.channel.invokeListMethod<String>('historyRoots'))!)
      Directory(path),
  ];
}

final class RecoveryRefused implements Exception {
  final String reason;
  const RecoveryRefused(this.reason);
}

/// Only this explicit-button coordinator may commit a selection. The older
/// diagnostic API continues to return promotionAllowed=false for every result.
final class OneTapSqliteRecovery {
  final RecoveryHost host;
  final Future<void> Function(String step)? checkpoint;
  final void Function(Database candidate)? beforeReindex;
  bool _running = false;
  bool _committed = false;
  OneTapSqliteRecovery(this.host, {this.checkpoint, this.beforeReindex});

  Future<void> run() async {
    if (_committed) {
      throw const RecoveryRefused('already_committed');
    }
    if (_running) {
      throw const RecoveryRefused('already_running');
    }
    _running = true;
    String? token;
    Directory? attempt;
    SqliteRecoveryReport? report;
    SqliteWalEvidence? walEvidence;
    Map<String, String>? hashes;
    var promoted = false;
    try {
      final session = await host.begin();
      token = session.token;
      attempt = await session.root.createTemp('attempt-');
      await _at('blocked');
      hashes = await recoveryFileHashes(session.source);
      if (File('${session.source.path}-journal').existsSync()) {
        throw const RecoveryRefused('rollback_journal_requires_manual_recovery');
      }
      final bytes = await _sourceBytes(session.source);
      if (await host.availableBytes() < bytes * 6 + 64 * 1024 * 1024) {
        throw const RecoveryRefused('insufficient_space');
      }
      await _at('before_copy');
      final snapshot = await captureSqliteRecoverySnapshot(
        database: session.source,
        outputDirectory: attempt,
        maxAttempts: 1,
        afterFileCopied: (name) => _at("copy:$name"),
      );
      await _at('copied');
      final backup = File(p.join(snapshot.directory.path, p.basename(session.source.path)));
      if (!_equal(hashes, await recoveryFileHashes(backup)) ||
          !_equal(hashes, await recoveryFileHashes(session.source))) {
        throw const RecoveryRefused('source_or_backup_changed');
      }
      await host.sync(snapshot.directory);
      await _at('backup_durable');
      final history = (await host.historyRoots()).map((d) => d.path).toList();
      final proof = await _assessInWorker(snapshot.directory.path, history, attempt.path);
      walEvidence = proof;
      // Keep SQLite scans/REINDEX off the UI isolate. The native admission
      // owner remains held while this worker touches copies only.
      if (checkpoint == null && beforeReindex == null) {
        report = await _diagnoseInWorker(snapshot.directory.path, attempt.path);
      } else {
        report = await diagnoseAndRepairSqliteSnapshot(
          snapshot: snapshot.directory,
          outputDirectory: attempt,
          allowedIndexes: const {'idx_trashed_local_asset_album'},
          repairCheckpoint: checkpoint,
          beforeReindex: beforeReindex,
        );
      }
      // Diagnose copies even when completeness is unproven. The report can now
      // distinguish a failed check from one that never ran. Never promote merely
      // because a REINDEX made an older/incomplete view internally consistent.
      if (!proof.complete) {
        throw RecoveryRefused(proof.code);
      }
      if (report.status != SqliteRecoveryStatus.repairedIndex ||
          report.candidate == null ||
          report.candidateIntegrity != 'ok' ||
          report.foreignKeyErrors.isNotEmpty ||
          !_equal(report.sourceTableFingerprints, report.candidateTableFingerprints ?? {})) {
        throw const RecoveryRefused('index_only_repair_not_proven');
      }
      final candidate = File(p.join(report.candidate!.path, p.basename(session.source.path)));
      // Independently reopen the final, checkpointed candidate. Schema, rowid,
      // user_version and sqlite_sequence are part of the content comparison.
      await _validateInWorker(candidate.path, report.sourceTableFingerprints);
      if (!_equal(hashes, await recoveryFileHashes(session.source)) ||
          !_equal(hashes, await recoveryFileHashes(backup))) {
        throw const RecoveryRefused('source_or_backup_changed');
      }
      await _receipt(attempt, 'validated', report, hashes, walEvidence);
      await host.sync(attempt);
      await _at('before_promotion');
      // Repeat after any asynchronous boundary; promotion checks the exact file
      // hash again natively under the same admission owner.
      await _validateInWorker(candidate.path, report.sourceTableFingerprints);
      final digest = await recoveryFileHash(candidate);
      await host.promote(token, candidate, digest);
      promoted = true;
      _committed = true;
      SqliteRecoveryGate.clearAfterValidatedRecovery();
    } catch (error) {
      if (attempt != null) {
        try {
          await _receipt(
            attempt,
            error is RecoveryRefused ? error.reason : 'io_or_validation_failure',
            report,
            hashes,
            walEvidence,
          );
          await host.sync(attempt);
        } catch (_) {
          /* A full disk must not cause cleanup of the original. */
        }
      }
      rethrow;
    } finally {
      if (token != null && !promoted) {
        await host.finish(token);
      }
      _running = false;
    }
  }

  Future<void> _at(String step) async => checkpoint?.call(step);
}

Future<int> _sourceBytes(File database) async {
  var total = 0;
  for (final suffix in ['', '-wal', '-shm']) {
    final file = File('${database.path}$suffix');
    if (file.existsSync()) {
      total += await file.length();
    }
  }
  return total;
}

Future<String> recoveryFileHash(File file) async => (await sha256.bind(file.openRead()).first).toString();
Future<Map<String, String>> recoveryFileHashes(File database) async {
  final hashes = <String, String>{};
  for (final suffix in ['', '-wal', '-shm']) {
    final file = File('${database.path}$suffix');
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (suffix.isEmpty || type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.file) {
        throw const RecoveryRefused('source_file_unavailable');
      }
      hashes[suffix] = await recoveryFileHash(file);
    }
  }
  return hashes;
}

bool _equal(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((entry) => b[entry.key] == entry.value);
Future<void> _receipt(
  Directory directory,
  String outcome,
  SqliteRecoveryReport? report,
  Map<String, String>? hashes,
  SqliteWalEvidence? walEvidence,
) => File(p.join(directory.path, 'recovery-report.json')).writeAsString(
  jsonEncode({
    'format': 24, 'outcome': outcome, 'sourceChecksums': hashes,
    'walEvidence': walEvidence?.toJson(),
    'tablesChecked': report?.sourceTableFingerprints.keys.where((key) => !key.startsWith('@')).length ?? 0,
    'contentMatch': report?.candidateTableFingerprints == null
        ? null
        : _equal(report!.sourceTableFingerprints, report.candidateTableFingerprints!),
    // Raw SQLite messages can contain row identifiers: only structural counts
    // and enumerated reasons go into the automatic support receipt.
    'integrityOk': report?.candidateIntegrity == null ? null : report!.candidateIntegrity == 'ok',
    'integrityStatus': report?.candidateIntegrity == null
        ? 'not_run'
        : report!.candidateIntegrity == 'ok'
        ? 'passed'
        : 'failed',
    'foreignKeyErrors': report?.foreignKeyErrors.length,
    'diagnosticStatus': report?.status.name,
  }),
  flush: true,
);

Future<SqliteRecoveryReport> _diagnoseInWorker(String snapshot, String output) => Isolate.run(
  () => diagnoseAndRepairSqliteSnapshot(
    snapshot: Directory(snapshot),
    outputDirectory: Directory(output),
    allowedIndexes: const {'idx_trashed_local_asset_album'},
  ),
);
Future<SqliteWalEvidence> _assessInWorker(String snapshot, List<String> history, String attempt) => Isolate.run(
  () => assessSqliteWalEvidence(
    snapshot: Directory(snapshot),
    historyRoots: history.map(Directory.new).toList(),
    excludedAttempt: Directory(attempt),
  ),
);
Future<void> _validateInWorker(String candidate, Map<String, String> fingerprints) =>
    Isolate.run(() => validateRecoveredSqlite(File(candidate), fingerprints));
