import 'dart:io';

import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:sqlite3/sqlite3.dart';

import '../sqlite_one_tap_recovery_test.dart' show createRecoveryFixture;

/// Real SQLite TRUNCATE checkpoint. Copy while the connection remains open so
/// the current checkpoint header survives; the phone fixture has no open handle.
Future<File> createCheckpointFixture(Directory directory, {bool witness = true, bool loseLaterCommit = false}) async {
  final liveDir = await Directory('${directory.path}/live').create(recursive: true);
  final live = await createRecoveryFixture(liveDir);
  final phone = await Directory('${directory.path}/phone').create();
  final db = sqlite3.open(live.path);
  try {
    db.select('SELECT * FROM pending_upload');
    if (witness) {
      await captureSqliteRecoverySnapshot(database: live, outputDirectory: Directory('${phone.path}/sqlite-recovery'));
    }
    final result = db.select('PRAGMA wal_checkpoint(TRUNCATE)').single;
    if (result.values.first != 0) {
      throw StateError('Checkpoint did not finish');
    }
    for (final suffix in ['', '-wal', '-shm']) {
      await File('${live.path}$suffix').copy('${phone.path}/immich.sqlite$suffix');
    }
    if (loseLaterCommit) {
      // A simulated power-loss persistence image: SQLite's transient SHM is
      // not a durable commit journal. The phone image retains checkpoint bytes
      // while later real WAL-only commits are lost with the WAL. Do not claim
      // this is a hardware power-cut test.
      db.execute("INSERT INTO pending_upload VALUES ('later-committed-upload')");
      db.execute("UPDATE pending_delete SET acknowledged=1 WHERE id='delete-wal-only'");
      if (db.select("SELECT id FROM pending_upload WHERE id='later-committed-upload'").length != 1 ||
          File('${live.path}-wal').lengthSync() <= 32) {
        throw StateError('Later real WAL commit was not created');
      }
    }
  } finally {
    db.close();
  }
  return File('${phone.path}/immich.sqlite');
}
