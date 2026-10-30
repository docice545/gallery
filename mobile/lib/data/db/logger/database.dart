import 'package:drift/drift.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:immich_mobile/data/db/logger/database.drift.dart';
import 'package:immich_mobile/data/db/logger/table/log.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:sqlite_async/sqlite_async.dart';

@DriftDatabase(tables: [LogMessageEntity])
class DriftLogger extends $DriftLogger {
  final SqliteConnection? _ownedConnection;

  DriftLogger.fromExecutor(super.executor) : _ownedConnection = null;

  DriftLogger.sqlite(SqliteConnection db) : _ownedConnection = db, super(SqliteAsyncDriftConnection(db));

  @override
  Future<void> close() async {
    await super.close();
    await _ownedConnection?.close();
  }

  @override
  int get schemaVersion => 1;

  Future<void> optimize() async {
    try {
      await customStatement('PRAGMA optimize=0x10002');
    } catch (error) {
      dPrint(() => 'Failed to optimize logger database: $error');
    }
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA synchronous = NORMAL');
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA busy_timeout = 30000'); // 30s
      await customStatement('PRAGMA cache_size = -32000'); // 32MB
      await customStatement('PRAGMA temp_store = MEMORY');
    },
  );
}
