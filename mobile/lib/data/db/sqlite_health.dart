import 'package:sqlite3/common.dart';

/// The primary SQLite database must never be deleted or reset automatically.
/// These helpers centralize the error classification used by startup and sync
/// callers so corruption is treated as a stop condition rather than a retryable
/// sync failure.
enum SqliteHealthFailure { corrupt, notADatabase, io, full, other }

SqliteHealthFailure classifySqliteFailure(SqliteException error) {
  // sqlite3 exposes extended result codes (for example SQLITE_CORRUPT_INDEX =
  // 779). The low byte is always the primary result code.
  final primaryCode = error.resultCode & 0xff;
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
