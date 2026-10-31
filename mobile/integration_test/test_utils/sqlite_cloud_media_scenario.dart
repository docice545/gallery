// Synthetic debug account only. The host helper operates actual Shizuku and
// Android Photo Picker UI; no provider/query/permission mocks are installed.
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_platform.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/cloud_media.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/background_worker_lock_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../../test/data/db/fixtures/recovery_http_server.dart';
import 'open_foto.dart';

void cloudMediaScenario({required bool restart}) {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('restored generation survives real Shizuku, native picker reads and restart=$restart', (tester) async {
    await BackgroundWorkerLockService(BackgroundWorkerLockApi()).lock();
    final directory = await getApplicationDocumentsDirectory();
    final original = File('${directory.path}/immich.sqlite');
    final marker = jsonDecode(await File('${directory.path}/build23-upgrade.json').readAsString()) as Map;
    expect(await recoveryFileHashes(original), marker['sourceChecksums']);
    final selected = await SqliteRecoveryPlatform.selected();
    expect(selected.path, isNot(original.path));
    final phase = File('${directory.path}/cloud24-phase-${restart ? 'restart' : 'first'}');
    final server = (await RecoveryHttpServer.start(port: 8765))
      ..fullFoto = true
      ..fullDownloadResets = 1; // The same server session already completed its first full download.
    addTearDown(server.close);
    await EasyLocalization.ensureInitialized();
    await openFotoForTest(); // real full integrity startup probe, existing account/router/pool
    await waitUntil(tester, () async => find.byType(ThumbnailTile).evaluate().isNotEmpty);
    expect(StoreService.I.get(StoreKey.currentUser).id, 'existing-owner');
    expect(SettingsRepository.instance.appConfig.backup.enabled, false);
    expect(StoreService.I.get(StoreKey.manageLocalMediaAndroid), false);
    // The synthetic server asset needs its normal EXIF size to be picker-eligible.
    final (connection, updates) = await openSqliteConnectionWithUpdatePool(name: 'immich');
    final inspect = Drift.sqlite(connection, updates);
    await inspect.customStatement('INSERT OR REPLACE INTO remote_exif_entity(asset_id,file_size) VALUES (?,?)', [
      RecoveryHttpServer.photoId,
      68,
    ]);
    await inspect.close();
    const cloud = CloudMediaRepository();
    final before = await cloud.status();
    expect(before['signedIn'], true);
    expect(before['sqliteReaderReady'], true);
    expect((before['sqlite']! as Map)['status'], 'ready');
    await phase.writeAsString('healthy', flush: true);
    await waitUntil(tester, () async => (await cloud.status())['shizukuRunning'] == true);
    final enabled = await cloud.enable().timeout(const Duration(seconds: 60));
    expect(enabled['enabled'], true);
    await waitUntil(tester, () async => (await cloud.status())['admitted'] == true);
    // Re-activation must be idempotent and may not select/reset a SQLite generation.
    expect((await cloud.enable())['enabled'], true);
    expect((await SqliteRecoveryPlatform.selected()).path, selected.path);
    await phase.writeAsString('settings', flush: true);
    await cloud.openPickerSettings();
    await waitUntil(tester, () async => (await cloud.status())['selected'] == true);
    await phase.writeAsString('picker', flush: true);
    await waitUntil(tester, () async {
      final status = await cloud.status();
      return (status['pickerQueries']! as num) > 0 && (status['pickerRows']! as num) > 0;
    });
    await phase.writeAsString('verified', flush: true);
    await waitUntil(
      tester,
      () async => File('${directory.path}/cloud24-ui-returned-${restart ? 'restart' : 'first'}').existsSync(),
    );
    final after = await cloud.diagnose();
    expect((after['sqlite']! as Map)['status'], 'ready');
    expect(after['enabled'], true);
    expect(after['selected'], true);
    expect((await SqliteRecoveryPlatform.selected()).path, selected.path);
    expect(await recoveryFileHashes(original), marker['sourceChecksums']);
    expect(server.fullDownloadResets, 1); // no repeated server cursor reset or recreated local DB
    await File('${directory.path}/cloud24-${restart ? 'restart' : 'first'}-report.json').writeAsString(
      jsonEncode({
        'format': 24,
        'restart': restart,
        'sameGeneration': true,
        'sameOriginalChecksums': true,
        'accountRetained': true,
        'backupEnabled': false,
        'sqlite': after['sqlite'],
        'shizukuRunning': after['shizukuRunning'],
        'permissionGranted': after['permissionGranted'],
        'selected': after['selected'],
        'pickerQueries': after['pickerQueries'],
        'pickerRows': after['pickerRows'],
      }),
      flush: true,
    );
    await phase.writeAsString('done', flush: true);
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 8)));
}

Future<void> waitUntil(WidgetTester tester, Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  fail('Native/cloud scenario condition did not complete');
}
