import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Never persisted by the emergency viewer or included in a diagnostic report.
final class RecoveryServerCredentials {
  final String ownerId;
  final String token;
  final Uri endpoint;
  const RecoveryServerCredentials(this.ownerId, this.token, this.endpoint);
  @override
  String toString() => 'RecoveryServerCredentials(redacted)';
}

/// Take an exclusive, durable evidence copy before reading the saved session.
/// finish() keeps the persistent admission barrier. No Bootstrap/Store/pool or
/// account migration is initialized, and an older account snapshot is never used.
Future<RecoveryServerCredentials> captureRecoveryServerCredentials(RecoveryHost host) async {
  final session = await host.begin();
  try {
    if (File('${session.source.path}-journal').existsSync()) {
      throw const RecoveryRefused('rollback_journal_requires_manual_recovery');
    }
    final before = await recoveryFileHashes(session.source);
    final size = before.keys.fold<int>(0, (sum, suffix) => sum + File('${session.source.path}$suffix').lengthSync());
    if (await host.availableBytes() < size * 3 + 16 * 1024 * 1024) {
      throw const RecoveryRefused('insufficient_space');
    }
    final attempt = await session.root.createTemp('attempt-server-');
    final snapshot = await captureSqliteRecoverySnapshot(
      database: session.source,
      outputDirectory: attempt,
      maxAttempts: 1,
    );
    final backup = File(p.join(snapshot.directory.path, 'immich.sqlite'));
    if (!_equal(before, await recoveryFileHashes(backup)) ||
        !_equal(before, await recoveryFileHashes(session.source))) {
      throw const RecoveryRefused('source_or_backup_changed');
    }
    await host.sync(snapshot.directory);
    // SQLite may rebuild SHM only in this extra reading copy, never in evidence.
    final reading = await captureSqliteRecoverySnapshot(
      database: backup,
      outputDirectory: Directory(p.join(attempt.path, 'reading')),
      maxAttempts: 1,
    );
    final credentials = await _readInWorker(reading.directory.path);
    if (!_equal(before, await recoveryFileHashes(backup)) ||
        !_equal(before, await recoveryFileHashes(session.source))) {
      throw const RecoveryRefused('source_or_backup_changed');
    }
    await File(p.join(attempt.path, 'server-view-report.json')).writeAsString(
      jsonEncode({
        'format': 24,
        'mode': 'server_read_only',
        'localSyncEnabled': false,
        'primaryPromoted': false,
        'sourceChecksums': before,
      }),
      flush: true,
    );
    await host.sync(attempt);
    return credentials;
  } finally {
    await host.finish(session.token);
  }
}

bool _equal(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

Future<RecoveryServerCredentials> _readInWorker(String snapshot) =>
    Isolate.run(() => _readCredentials(Directory(snapshot)));

Future<RecoveryServerCredentials> _readCredentials(Directory snapshot) async {
  final primary = File(p.join(snapshot.path, 'immich.sqlite'));
  final wal = File('${primary.path}-wal');
  // An ambiguous nonempty WAL must not select a different/older saved account.
  if (wal.existsSync() && wal.lengthSync() > 0) {
    try {
      await validateSqliteRecoverySnapshotFiles(snapshot);
    } catch (_) {
      throw const RecoveryRefused('server_credentials_unavailable');
    }
  }
  Database? db;
  try {
    db = openSqliteStartupProbe(primary);
    db.execute('PRAGMA query_only=ON');
    final rows = db.select('SELECT id,string_value FROM store_entity NOT INDEXED WHERE id IN (2,11,12)');
    final values = {for (final row in rows) row['id']: row['string_value']};
    final owner = values[2];
    final token = values[11];
    final endpointValue = values[12];
    if (rows.length != 3 ||
        owner is! String ||
        owner.isEmpty ||
        token is! String ||
        token.isEmpty ||
        token.length > 16384 ||
        token.contains('\r') ||
        token.contains('\n') ||
        endpointValue is! String) {
      throw const RecoveryRefused('server_credentials_unavailable');
    }
    final endpoint = Uri.tryParse(endpointValue);
    if (endpoint == null ||
        !['https', 'http'].contains(endpoint.scheme) ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        db.select('SELECT id FROM auth_user_entity NOT INDEXED WHERE id=?', [owner]).length != 1) {
      throw const RecoveryRefused('server_credentials_unavailable');
    }
    return RecoveryServerCredentials(owner, token, endpoint);
  } on RecoveryRefused {
    rethrow;
  } catch (_) {
    throw const RecoveryRefused('server_credentials_unavailable');
  } finally {
    db?.close();
  }
}
