import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_platform.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/pages/common/sqlite_recovery.page.dart';
import 'package:immich_mobile/utils/app_asset_loader.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../test/data/db/fixtures/sqlite_account_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android 16 one tap validates complete WAL, promotes and reopens production account and queues', (
    tester,
  ) async {
    final info = await PackageInfo.fromPlatform();
    expect(info.packageName, 'de.opennoodle.gallery.debug');
    expect(info.buildNumber, '24');
    final source = await SqliteRecoveryPlatform.selected();
    expect(source.existsSync(), false); // separate fresh AVD, never erase an old fixture
    await createAccountRecoveryFixture(source.parent);
    expect(File('${source.path}-wal').lengthSync(), greaterThan(32));
    final beforeProbe = await recoveryFileHashes(source);
    await expectLater(openSqliteConnectionWithUpdatePool(name: 'immich'), throwsA(isA<SqliteDatabaseUnhealthy>()));
    final hashes = await recoveryFileHashes(source);
    // A reader of a live WAL may update SHM read marks, but never table/WAL bytes.
    // Recovery retains all three source files exactly as admitted after the probe.
    expect(hashes[''], beforeProbe['']);
    expect(hashes['-wal'], beforeProbe['-wal']);
    await EasyLocalization.ensureInitialized();
    final completed = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('ru')],
        startLocale: const Locale('ru'),
        fallbackLocale: const Locale('ru'),
        path: 'assets/i18n',
        assetLoader: const AppAssetLoader(),
        child: SqliteRecoveryPage(
          recoverAndOpen: () async {
            calls++;
            try {
              await OneTapSqliteRecovery(const AndroidRecoveryHost()).run();
              completed.complete();
            } catch (error, stack) {
              completed.completeError(error, stack);
              rethrow;
            }
          },
          exportBackup: () async => false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.tap(find.text('Восстановить и открыть FOTO'));
    await completed.future.timeout(const Duration(seconds: 60));
    expect(calls, 1);
    expect((await SqliteRecoveryPlatform.selected()).path, isNot(source.path));
    expect(await recoveryFileHashes(source), hashes);
    final (db, pool) = await openSqliteConnectionWithUpdatePool(name: 'immich');
    final drift = Drift.sqlite(db, pool);
    final store = await StoreService.create(storeRepository: StoreRepository(drift), listenUpdates: false);
    try {
      expect(store.get(StoreKey.currentUser).id, 'existing-owner');
      expect(store.get(StoreKey.accessToken), 'synthetic-token-stays-private');
      await drift.syncStreamRepository.recoverPendingTrashOperations();
      expect((await drift.syncStreamRepository.getPendingTrashOperations()).map((r) => r.id), ['pending-delete']);
      expect((await drift.backupRepository.getCandidates('existing-owner')).map((r) => r.id), ['pending-upload']);
      expect((await db.get("SELECT value FROM settings WHERE key='sync.cursor.regression'"))['value'], 'ack-42');
    } finally {
      await store.dispose();
      await drift.close();
    }
    await SqliteRecoveryPlatform.halt();
    expect(
      await SqliteRecoveryPlatform.channel.invokeMethod<bool>('export').timeout(const Duration(seconds: 90)),
      true,
    );
    await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
