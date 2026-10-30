import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_platform.dart';
import 'package:path/path.dart' as p;

/// Platform boundary: admission, capacity, fsync and atomic selection. Tests use
/// real SQLite files and a durable file selector, never mocked SQLite results.
abstract interface class RecoveryHost {
  Future<({File source, Directory root, String token})> begin();
  Future<int> availableBytes();
  Future<void> sync(Directory directory);
  Future<void> promote(String token, File candidate, String hash);
  Future<void> finish(String token);
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
  bool _running = false;
  OneTapSqliteRecovery(this.host, {this.checkpoint});

  Future<void> run() async {
    if (_running) {
      throw const RecoveryRefused('already_running');
    }
    _running = true;
    String? token;
    Directory? attempt;
    SqliteRecoveryReport? report;
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
      // A WAL-mode header cannot establish that an absent WAL never contained
      // committed transactions. Preserve evidence and refuse this ambiguity.
      final header = await backup.open();
      final List<int> bytesHeader;
      try {
        bytesHeader = await header.read(100);
      } finally {
        await header.close();
      }
      final wal = File('${backup.path}-wal');
      if (bytesHeader.length < 100 ||
          ((bytesHeader[18] == 2 || bytesHeader[19] == 2) && (!wal.existsSync() || await wal.length() == 0))) {
        throw const RecoveryRefused('missing_or_unprovable_wal');
      }
      report = await diagnoseAndRepairSqliteSnapshot(
        snapshot: snapshot.directory,
        outputDirectory: attempt,
        allowedIndexes: const {'idx_trashed_local_asset_album'},
        repairCheckpoint: checkpoint,
      );
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
      validateRecoveredSqlite(candidate, report.sourceTableFingerprints);
      if (!_equal(hashes, await recoveryFileHashes(session.source)) ||
          !_equal(hashes, await recoveryFileHashes(backup))) {
        throw const RecoveryRefused('source_or_backup_changed');
      }
      await _receipt(attempt, 'validated', report, hashes);
      await host.sync(attempt);
      await _at('before_promotion');
      // Repeat after any asynchronous boundary; promotion checks the exact file
      // hash again natively under the same admission owner.
      validateRecoveredSqlite(candidate, report.sourceTableFingerprints);
      final digest = await recoveryFileHash(candidate);
      await host.promote(token, candidate, digest);
      promoted = true;
      SqliteRecoveryGate.clearAfterValidatedRecovery();
    } catch (error) {
      if (attempt != null) {
        try {
          await _receipt(attempt, error is RecoveryRefused ? error.reason : 'io_or_validation_failure', report, hashes);
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
Future<void> _receipt(Directory directory, String outcome, SqliteRecoveryReport? report, Map<String, String>? hashes) =>
    File(p.join(directory.path, 'recovery-report.json')).writeAsString(
      jsonEncode({
        'format': 23, 'outcome': outcome, 'sourceChecksums': hashes,
        'tablesChecked': report?.sourceTableFingerprints.keys.where((key) => !key.startsWith('@')).length ?? 0,
        'contentMatch':
            report?.candidateTableFingerprints != null &&
            _equal(report!.sourceTableFingerprints, report.candidateTableFingerprints!),
        // Raw SQLite messages can contain row identifiers: only structural counts
        // and enumerated reasons go into the automatic support receipt.
        'integrityOk': report?.candidateIntegrity == 'ok',
        'foreignKeyErrors': report?.foreignKeyErrors.length,
        'diagnosticStatus': report?.status.name,
      }),
      flush: true,
    );
