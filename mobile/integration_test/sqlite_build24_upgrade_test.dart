import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_platform.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_server.dart';
import 'package:immich_mobile/pages/common/sqlite_recovery.page.dart';
import 'package:immich_mobile/services/recovery_server.service.dart';
import 'package:immich_mobile/utils/app_asset_loader.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../test/data/db/fixtures/recovery_http_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Build 23 to 24 upgrade preserves Samsung evidence and opens server photos with one tap', (tester) async {
    final info = await PackageInfo.fromPlatform();
    expect(info.packageName, 'de.opennoodle.gallery.debug');
    expect(info.buildNumber, '24');
    final source = await SqliteRecoveryPlatform.selected();
    final marker = jsonDecode(await File('${source.parent.path}/build23-upgrade.json').readAsString()) as Map;
    final hashes = marker['sourceChecksums'];
    expect(await recoveryFileHashes(source), hashes);
    expect(await recoveryFileHash(File(marker['reportPath'] as String)), marker['reportChecksum']);
    await expectLater(openSqliteConnectionWithUpdatePool(name: 'immich'), throwsA(isA<SqliteDatabaseUnhealthy>()));
    final server = await RecoveryHttpServer.start(port: 8765);
    addTearDown(server.close);
    await EasyLocalization.ensureInitialized();
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('ru')],
        startLocale: const Locale('ru'),
        fallbackLocale: const Locale('ru'),
        path: 'assets/i18n',
        assetLoader: const AppAssetLoader(),
        child: SqliteRecoveryPage(
          recoverAndOpen: () => OneTapSqliteRecovery(const AndroidRecoveryHost()).run(),
          exportBackup: () async => (await SqliteRecoveryPlatform.channel.invokeMethod<bool>('export'))!,
          openServerPhotos: () async =>
              RecoveryServerClient(await captureRecoveryServerCredentials(const AndroidRecoveryHost())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Восстановить и открыть FOTO'));
    await waitFor(tester, find.textContaining('empty_wal_evidence_missing'));
    expect(await recoveryFileHashes(source), hashes);
    await tester.tap(find.text('Открыть серверные фотографии'));
    await waitFor(tester, find.byKey(const ValueKey('server-photo-${RecoveryHttpServer.photoId}')));
    expect(find.text('Existing owner'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('server-photo-${RecoveryHttpServer.photoId}')));
    await tester.pumpAndSettle();
    expect(server.requests.any((r) => r.uri.queryParameters['size'] == 'preview'), true);
    expect(server.requests.every((r) => r.method == 'GET' && r.authenticated), true);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(await recoveryFileHashes(source), hashes);
    expect((await SqliteRecoveryPlatform.selected()).path, source.path);
    await expectLater(SqliteRecoveryPlatform.acquire(), throwsA(isA<SqliteDatabaseUnhealthy>()));
    expect(await recoveryFileHash(File(marker['reportPath'] as String)), marker['reportChecksum']);
    // Real DocumentsUI, operated by the emulator-only CI helper.
    expect(
      await SqliteRecoveryPlatform.channel.invokeMethod<bool>('export').timeout(const Duration(seconds: 90)),
      true,
    );
  }, timeout: const Timeout(Duration(minutes: 4)));
}

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(finder, findsOneWidget);
}
