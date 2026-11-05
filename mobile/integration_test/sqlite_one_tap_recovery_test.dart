import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_platform.dart';
import 'package:immich_mobile/pages/common/sqlite_recovery.page.dart';
import 'package:immich_mobile/utils/app_asset_loader.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../test/data/db/sqlite_one_tap_recovery_test.dart' show createRecoveryFixture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android native admission, fsync and selection preserve actual WAL files after one tap', (tester) async {
    final info = await PackageInfo.fromPlatform();
    expect(info.packageName, 'de.opennoodle.gallery.debug');
    expect(info.version, startsWith('5.7.3'));
    expect(info.buildNumber, '23');
    final original = await SqliteRecoveryPlatform.selected();
    // Never overwrite any existing database, even in the isolated test package.
    expect(original.existsSync(), false);
    final source = await createRecoveryFixture(original.parent);
    expect(source.path, original.path);
    final beforeProbe = await recoveryFileHashes(source);
    await expectLater(openSqliteConnectionWithUpdatePool(name: 'immich'), throwsA(isA<SqliteDatabaseUnhealthy>()));
    await expectLater(SqliteRecoveryPlatform.acquire(), throwsA(isA<SqliteDatabaseUnhealthy>()));
    final hashes = await recoveryFileHashes(source);
    expect(hashes[''], beforeProbe['']);
    expect(hashes['-wal'], beforeProbe['-wal']);
    await EasyLocalization.ensureInitialized();
    final completed = Completer<void>();
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('ru')],
        startLocale: const Locale('ru'),
        fallbackLocale: const Locale('ru'),
        path: 'assets/i18n',
        assetLoader: const AppAssetLoader(),
        child: SqliteRecoveryPage(
          recoverAndOpen: () async {
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
    expect(completed.isCompleted, false);
    expect(find.text('Требуется восстановление FOTO'), findsOneWidget);
    await tester.tap(find.text('Восстановить и открыть FOTO'));
    await completed.future.timeout(const Duration(seconds: 60));
    final active = await SqliteRecoveryPlatform.selected();
    expect(active.path, isNot(source.path));
    expect(await recoveryFileHashes(source), hashes);
    final (db, pool) = await openSqliteConnectionWithUpdatePool(name: 'immich');
    expect((await db.get('SELECT id FROM pending_upload'))['id'], 'upload-wal-only');
    expect((await db.get("SELECT value FROM settings WHERE key='account'"))['value'], 'existing-owner');
    await Drift.sqlite(db, pool).close();
    // Incomplete operations and originals remain inside persistent private storage.
    expect(File('${source.path}-wal').existsSync(), true);
    await SqliteRecoveryPlatform.halt();
    // CI selects Save in the real Android DocumentsUI; the ZIP is verified
    // independently after flutter test exits. No network destination is used.
    expect(
      await SqliteRecoveryPlatform.channel.invokeMethod<bool>('export').timeout(const Duration(seconds: 90)),
      true,
    );
    await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
