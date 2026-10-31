import 'dart:io';

import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:sqlite3/sqlite3.dart';

import '../sqlite_one_tap_recovery_test.dart' show createRecoveryFixture;

/// Real SQLite TRUNCATE checkpoint. Copy while the connection remains open so
/// the current checkpoint header survives; the phone fixture has no open handle.
Future<File> createCheckpointFixture(Directory directory, {bool witness = true}) async {
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
  } finally {
    db.close();
  }
  return File('${phone.path}/immich.sqlite');
}
