import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart';

/// The primary SQLite database must never be deleted or reset automatically.
/// These helpers centralize the error classification used by startup and sync
/// callers so corruption is treated as a stop condition rather than a retryable
/// sync failure.
enum SqliteHealthFailure { corrupt, notADatabase, io, full, other }

// SQLITE_CORRUPT_INDEX is SQLITE_CORRUPT (11) with extended code 3.
const _sqliteCorruptIndexResultCode = SqlError.SQLITE_CORRUPT | (3 << 8);

SqliteHealthFailure classifySqliteFailure(SqliteException error) =>
    classifySqliteResultCode(error.extendedResultCode);

/// Classifies both primary and extended SQLite result codes. Keep this
/// separate from [classifySqliteFailure] so the recovery gate can be tested
/// against the exact SQLITE_CORRUPT_INDEX value (779) without manufacturing a
/// platform exception.
SqliteHealthFailure classifySqliteResultCode(int resultCode) {
  if (resultCode == _sqliteCorruptIndexResultCode) {
    return SqliteHealthFailure.corrupt;
  }

  // sqlite3 exposes extended result codes (for example SQLITE_CORRUPT_INDEX =
  // 779). The low byte is always the primary result code.
  final primaryCode = resultCode & 0xff;
  return switch (primaryCode) {
    SqlError.SQLITE_CORRUPT => SqliteHealthFailure.corrupt,
    SqlError.SQLITE_NOTADB => SqliteHealthFailure.notADatabase,
    SqlError.SQLITE_IOERR => SqliteHealthFailure.io,
    SqlError.SQLITE_FULL => SqliteHealthFailure.full,
    _ => SqliteHealthFailure.other,
  };
}

bool isUnsafeToWrite(SqliteException error) {
  return switch (classifySqliteFailure(error)) {
    SqliteHealthFailure.corrupt ||
    SqliteHealthFailure.notADatabase ||
    SqliteHealthFailure.io ||
    SqliteHealthFailure.full => true,
    SqliteHealthFailure.other => false,
  };
}

/// Raised after a primary database health check fails. The original database
/// files remain untouched; recovery must be performed against a copy.
final class SqliteDatabaseUnhealthy implements Exception {
  final String check;
  final Object cause;

  const SqliteDatabaseUnhealthy(this.check, this.cause);

  @override
  String toString() => 'Primary SQLite database failed $check ($cause)';
}

/// Process-local stop gate for sync work after a write-path corruption error.
///
/// A failed transaction is rolled back by Drift, so pending operations remain
/// in the primary database. The gate prevents the same stream from immediately
/// retrying against the damaged index. It is deliberately not persisted or
/// cleared automatically: the caller must validate a repaired copy and then
/// explicitly clear it after the approved recovery has been applied.
final class SqliteRecoveryGate {
  static bool _halted = false;
  static String? _check;
  static int? _resultCode;

  static bool get isHalted => _halted;
  static String? get check => _check;
  static int? get resultCode => _resultCode;

  static void markRequired({required String check, required int resultCode}) {
    _halted = true;
    _check = check;
    _resultCode = resultCode;
  }

  /// Throws before a new sync attempt can reach the damaged database.
  static void throwIfRequired([String? operation]) {
    if (!_halted) {
      return;
    }
    throw SqliteDatabaseUnhealthy(
      operation ?? _check ?? 'SQLite sync write',
      _resultCode ?? 'recovery required',
    );
  }

  /// Releases the barrier after a user-mediated recovery has validated a
  /// repaired candidate and explicitly restored it through the approved flow.
  static void clearAfterValidatedRecovery() {
    _halted = false;
    _check = null;
    _resultCode = null;
  }
}

/// A non-destructive copy of a SQLite database and any WAL/SHM sidecars.
///
/// The snapshot is written into a staging directory and atomically renamed
/// only after all source files remain unchanged for the duration of the copy.
/// This prevents exporting a mixture of old and new pages while the app is
/// still running. It does not mutate, checkpoint, or delete the source DB.
final class SqliteRecoverySnapshot {
  final Directory directory;
  final File manifest;
  final List<File> files;
  final DateTime capturedAt;

  const SqliteRecoverySnapshot({
    required this.directory,
    required this.manifest,
    required this.files,
    required this.capturedAt,
  });
}

final class SqliteRecoveryCaptureException implements Exception {
  final String message;
  final Object? cause;

  const SqliteRecoveryCaptureException(this.message, [this.cause]);

  @override
  String toString() => cause == null ? message : '$message ($cause)';
}

/// Captures an intact copy of [database] and its `-wal`/`-shm` sidecars.
///
/// Callers should invoke this before any repair or reset action. A changing
/// source causes a retry and then a diagnostic failure; the source is never
/// removed or replaced. The resulting directory contains a machine-readable
/// manifest suitable for support upload or user-selected export.
Future<SqliteRecoverySnapshot> captureSqliteRecoverySnapshot({
  required File database,
  required Directory outputDirectory,
  String? reason,
  DateTime Function()? now,
  int maxAttempts = 3,
}) async {
  if (maxAttempts < 1) {
    throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be at least one');
  }

  final exists = database.existsSync();
  if (!exists) {
    throw SqliteRecoveryCaptureException('Primary SQLite database does not exist: ${database.path}');
  }

  await outputDirectory.create(recursive: true);
  final capturedAt = (now ?? DateTime.now)().toUtc();
  final baseName = 'sqlite-recovery-${capturedAt.microsecondsSinceEpoch}';
  var snapshotName = baseName;
  var suffix = 0;
  while (Directory(p.join(outputDirectory.path, snapshotName)).existsSync()) {
    suffix++;
    snapshotName = '$baseName-$suffix';
  }
  final staging = Directory(p.join(outputDirectory.path, '.$snapshotName.staging'));
  final destination = Directory(p.join(outputDirectory.path, snapshotName));

  Object? lastError;
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      await staging.delete(recursive: true).catchError((_) => staging);
      await staging.create(recursive: true);

      final sourcePaths = <String>[
        database.path,
        '${database.path}-wal',
        '${database.path}-shm',
      ];
      final before = await _sqliteFileStats(sourcePaths);
      if (before[database.path]?.exists != true) {
        throw const SqliteRecoveryCaptureException('Primary SQLite database disappeared before capture');
      }

      final copied = <String, File>{};
      final omittedSidecars = <String>[];
      for (final sourcePath in sourcePaths) {
        final stat = before[sourcePath];
        if (stat?.exists != true) {
          continue;
        }
        final target = File(p.join(staging.path, p.basename(sourcePath)));
        try {
          await File(sourcePath).copy(target.path);
          copied[sourcePath] = target;
        } on FileSystemException catch (error) {
          // SQLite may remove a WAL/SHM sidecar while a connection closes.
          // The primary file is still mandatory; a sidecar that vanished is
          // omitted and recorded rather than turning recovery into a reset.
          if (sourcePath == database.path || !_isMissingFile(error)) {
            rethrow;
          }
          omittedSidecars.add(p.basename(sourcePath));
        }
      }

      final after = await _sqliteFileStats(sourcePaths);
      if (before[database.path] != after[database.path]) {
        throw const SqliteRecoveryCaptureException('SQLite files changed during capture; retrying safely');
      }

      // A sidecar is evidence only when it remained byte-addressable for the
      // whole copy. Keep the stable files, drop a sidecar that disappeared or
      // changed, and make the omission explicit in the manifest. The primary
      // database is never replaced or checkpointed by this path.
      final stableSourcePaths = <String>[database.path];
      for (final sourcePath in sourcePaths.skip(1)) {
        final copiedFile = copied[sourcePath];
        if (copiedFile == null) {
          continue;
        }
        if (before[sourcePath] == after[sourcePath]) {
          stableSourcePaths.add(sourcePath);
        } else {
          await copiedFile.delete().catchError((_) => copiedFile);
          copied.remove(sourcePath);
          omittedSidecars.add(p.basename(sourcePath));
        }
      }

      final manifest = File(p.join(staging.path, 'manifest.json'));
      final manifestData = <String, Object?>{
        'format': 1,
        'capturedAt': capturedAt.toIso8601String(),
        'database': p.basename(database.path),
        if (omittedSidecars.isNotEmpty) 'omittedSidecars': omittedSidecars.toSet().toList()..sort(),
        'files': [
          for (final sourcePath in stableSourcePaths)
            if (copied[sourcePath] != null)
              {
                'name': p.basename(sourcePath),
                'bytes': before[sourcePath]!.bytes,
                'modifiedAt': before[sourcePath]!.modifiedAt?.toUtc().toIso8601String(),
              },
        ],
      };
      if (reason != null) {
        manifestData['reason'] = reason;
      }
      await manifest.writeAsString(const JsonEncoder.withIndent('  ').convert(manifestData));

      await staging.rename(destination.path);
      return SqliteRecoverySnapshot(
        directory: destination,
        manifest: File(p.join(destination.path, 'manifest.json')),
        files: [for (final file in copied.values) File(p.join(destination.path, p.basename(file.path)))],
        capturedAt: capturedAt,
      );
    } on SqliteRecoveryCaptureException catch (error) {
      lastError = error;
    } on Object catch (error) {
      lastError = error;
    } finally {
      // A successful capture moved staging to destination, so this is a no-op.
      await staging.delete(recursive: true).catchError((_) => staging);
    }
  }

  throw SqliteRecoveryCaptureException(
    'Unable to capture a consistent SQLite snapshot after $maxAttempts attempts',
    lastError,
  );
}

final class _SqliteFileStat {
  final bool exists;
  final int bytes;
  final DateTime? modifiedAt;

  const _SqliteFileStat({required this.exists, this.bytes = 0, this.modifiedAt});

  @override
  bool operator ==(Object other) {
    return other is _SqliteFileStat &&
        exists == other.exists &&
        bytes == other.bytes &&
        modifiedAt == other.modifiedAt;
  }

  @override
  int get hashCode => Object.hash(exists, bytes, modifiedAt);
}

Future<Map<String, _SqliteFileStat>> _sqliteFileStats(List<String> paths) async {
  final result = <String, _SqliteFileStat>{};
  for (final path in paths) {
    try {
      final stat = File(path).statSync();
      result[path] = _SqliteFileStat(exists: true, bytes: stat.size, modifiedAt: stat.modified);
    } on FileSystemException {
      result[path] = const _SqliteFileStat(exists: false);
    }
  }
  return result;
}

bool _isMissingFile(FileSystemException error) {
  final code = error.osError?.errorCode;
  return code == 2 || code == 3;
}
