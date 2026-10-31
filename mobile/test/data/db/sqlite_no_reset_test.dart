import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqlite3/sqlite3.dart';

final class _Documents extends PathProviderPlatform {
  final String path;
  _Documents(this.path);
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  test('legacy deletion helper refuses the primary and preserves real WAL-only pending work', () async {
    final directory = await Directory.systemTemp.createTemp('foto24-no-reset-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Documents(directory.path);
    final file = File('${directory.path}/immich.sqlite');
    final db = sqlite3.open(file.path);
    try {
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('CREATE TABLE pending_upload(id INTEGER PRIMARY KEY)');
      db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      db.execute('INSERT INTO pending_upload VALUES (7)');
      final before = await recoveryFileHashes(file);
      expect(File('${file.path}-wal').lengthSync(), greaterThan(32));
      await expectLater(deleteSqliteDatabase(name: 'immich'), throwsStateError);
      expect(await recoveryFileHashes(file), before);
      // Recreating the independent diagnostic log remains supported.
      final log = File('${directory.path}/immich_logs.sqlite')..writeAsStringSync('broken diagnostic log');
      await deleteSqliteDatabase(name: 'immich_logs');
      expect(log.existsSync(), false);
      expect(await recoveryFileHashes(file), before);
      expect(db.select('SELECT id FROM pending_upload').single['id'], 7);
      expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
    } finally {
      db.close();
      PathProviderPlatform.instance = previous;
      await directory.delete(recursive: true);
    }
  });
}
