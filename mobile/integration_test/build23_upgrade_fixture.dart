// CI copies this test and its synthetic account helper into the pinned, separate
// Build 23 checkout. It must execute Build 23 production code, not Build 24 mocks.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_platform.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../test/data/db/fixtures/sqlite_account_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Build 23 original probe and recovery reproduce canonical Samsung WAL refusal', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final info = await PackageInfo.fromPlatform();
    expect(info.packageName, 'de.opennoodle.gallery.debug');
    expect(info.buildNumber, '23');
    final source = await SqliteRecoveryPlatform.selected();
    expect(source.existsSync(), false);
    await createAccountRecoveryFixture(source.parent, checkpoint: true, endpoint: 'http://127.0.0.1:8765/api');
    await expectLater(openSqliteConnectionWithUpdatePool(name: 'immich'), throwsA(isA<SqliteDatabaseUnhealthy>()));
    final hashes = await recoveryFileHashes(source);
    expect(hashes['-wal'], 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(hashes['-shm'], 'fd4c9fda9cd3f9ae7c962b0ddf37232294d55580e1aa165aa06129b8549389eb');
    await expectLater(
      OneTapSqliteRecovery(const AndroidRecoveryHost()).run(),
      throwsA(isA<RecoveryRefused>().having((e) => e.reason, 'reason', 'missing_or_unprovable_wal')),
    );
    expect(await recoveryFileHashes(source), hashes);
    final session = await const AndroidRecoveryHost().begin();
    try {
      final reports = session.root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('recovery-report.json'))
          .toList();
      expect(reports.length, 1);
      final report = jsonDecode(reports.single.readAsStringSync()) as Map;
      expect(report['format'], 23);
      expect(report['tablesChecked'], 0);
      await File('${source.parent.path}/build23-upgrade.json').writeAsString(
        jsonEncode({
          'sourceChecksums': hashes,
          'reportPath': reports.single.path,
          'reportChecksum': await recoveryFileHash(reports.single),
        }),
        flush: true,
      );
      await const AndroidRecoveryHost().sync(source.parent);
    } finally {
      await const AndroidRecoveryHost().finish(session.token);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
