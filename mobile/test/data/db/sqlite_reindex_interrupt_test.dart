import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';

import 'sqlite_one_tap_recovery_test.dart' show FileRecoveryHost, createRecoveryFixture;

void main() {
  test(
    'SIGKILL during real REINDEX never promotes; next process recovers all rows',
    () async {
      final directory = await Directory.systemTemp.createTemp('foto23-interrupt-');
      addTearDown(() => directory.delete(recursive: true));
      final source = await createRecoveryFixture(directory);
      final before = await recoveryFileHashes(source);
      final host = FileRecoveryHost(source, Directory('${directory.path}/recovery'));
      final child = await Process.start(
        'setsid',
        ['flutter', 'test', '--no-pub', '--reporter', 'expanded', 'test/data/db/fixtures/reindex_crash_child.dart'],
        environment: {'FOTO23_CRASH_FIXTURE': directory.path},
      );
      final log = StringBuffer();
      final output = child.stdout.transform(utf8.decoder).listen(log.write);
      final errors = child.stderr.transform(utf8.decoder).listen(log.write);
      var exited = false;
      unawaited(
        child.exitCode.then((_) {
          exited = true;
        }),
      );
      final marker = File('${directory.path}/inside-reindex');
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (!marker.existsSync() && !exited && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(marker.existsSync(), true, reason: 'Child must reach the executing SQLite comparator: $log');
      } finally {
        await Process.run('kill', ['-KILL', '--', '-${child.pid}']);
        await child.exitCode;
        await output.cancel();
        await errors.cancel();
      }
      expect(host.selected.path, source.path);
      expect(await recoveryFileHashes(source), before);
      await OneTapSqliteRecovery(FileRecoveryHost(source, host.root)).run();
      expect(host.selected.path, isNot(source.path));
      expect(await recoveryFileHashes(source), before);
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
