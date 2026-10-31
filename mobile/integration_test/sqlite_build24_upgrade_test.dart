import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_fresh_start.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_platform.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_server.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/main.dart' as application;
import 'package:immich_mobile/pages/common/sqlite_recovery.page.dart';
import 'package:immich_mobile/platform/background_worker_lock_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/services/recovery_server.service.dart';
import 'package:immich_mobile/utils/app_asset_loader.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../test/data/db/fixtures/recovery_http_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Build 23 to 24 upgrade preserves Samsung evidence and opens server photos with one tap', (tester) async {
    await BackgroundWorkerLockService(BackgroundWorkerLockApi()).lock();
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
    final fresh = FreshSqliteStart(const AndroidFreshStartHost());
    final opened = Completer<void>();
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
          prepareFreshStart: fresh.prepare,
          startFreshAndOpen: (preparation) async {
            try {
              expect(preparation.needsLogin, false);
              await fresh.run(preparation, consent: true);
              await application.openFoto();
              opened.complete();
            } catch (error, stack) {
              opened.completeError(error, stack);
              rethrow;
            }
          },
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
    // The second, distinct SAF document must pass native fsync + full readback.
    // Only then can this unchecked loss warning authorize a new generation.
    server.fullFoto = true;
    await tester.tap(find.text('Начать заново с серверными фотографиями'));
    await waitFor(tester, find.byType(CheckboxListTile));
    final confirm = find.widgetWithText(FilledButton, 'Создать новую локальную библиотеку');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    expect((await SqliteRecoveryPlatform.selected()).path, source.path);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(confirm);
    await opened.future.timeout(const Duration(seconds: 60));
    await waitFor(tester, find.byType(ThumbnailTile).first);
    expect(StoreService.I.get(StoreKey.currentUser).id, 'existing-owner');
    expect(SettingsRepository.instance.appConfig.backup.enabled, false);
    expect(SettingsRepository.instance.appConfig.backup.syncAlbums, false);
    expect(StoreService.I.get(StoreKey.manageLocalMediaAndroid), false);
    expect(server.fullDownloadResets, 1);
    expect(server.acknowledged, contains('fresh-AlbumToAssetV1'));
    expect(
      server.requests
          .where((r) => r.method != 'GET')
          .every(
            (r) =>
                ['/api/sync/ack', '/api/sync/stream', '/api/auth/validateToken'].contains(r.uri.path) &&
                r.authenticated,
          ),
      true,
    );
    expect(await recoveryFileHashes(source), hashes);
    expect(await recoveryFileHash(File(marker['reportPath'] as String)), marker['reportChecksum']);
    final selected = await SqliteRecoveryPlatform.selected();
    expect(selected.path, isNot(source.path));
    // Native admission + normal app initialization is now running the new DB.
    // Inspect the new active generation through the normal pool factory, then close both handles.
    final (db, pool) = await openSqliteConnectionWithUpdatePool(name: 'immich');
    expect((await db.get('SELECT id FROM remote_album_entity'))['id'], RecoveryHttpServer.albumId);
    expect((await db.get('SELECT COUNT(*) AS n FROM local_album_entity WHERE backup_selection != 0'))['n'], 0);
    await Drift.sqlite(db, pool).close();
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 6)));
}

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(finder, findsOneWidget);
}
