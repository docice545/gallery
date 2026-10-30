import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';

import '../sqlite_one_tap_recovery_test.dart' show FileRecoveryHost;

void main() {
  test('child process stopped inside SQLite REINDEX', () async {
    final directory = Directory(Platform.environment['FOTO23_CRASH_FIXTURE']!);
    final source = File('${directory.path}/immich.sqlite');
    final host = FileRecoveryHost(source, Directory('${directory.path}/recovery'));
    await OneTapSqliteRecovery(
      host,
      beforeReindex: (db) {
        // SQLite calls this comparator from the executing REINDEX VM. The parent
        // kills this whole process group only after the durable marker appears.
        db.createCollation(
          name: 'BINARY',
          function: (left, right) {
            File('${directory.path}/inside-reindex').writeAsStringSync('executing', flush: true);
            while (true) {
              sleep(const Duration(milliseconds: 100));
            }
          },
        );
      },
    ).run();
    fail('parent must kill the process before promotion');
  });
}
