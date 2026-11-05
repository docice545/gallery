import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_server.dart';
import 'package:immich_mobile/pages/common/sqlite_recovery.page.dart';
import 'package:immich_mobile/services/recovery_server.service.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../data/db/fixtures/recovery_http_server.dart';
import '../../data/db/fixtures/sqlite_account_fixture.dart';
import '../../data/db/sqlite_one_tap_recovery_test.dart' show FileRecoveryHost;
import 'sqlite_recovery_page_test.dart' show localized;

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  testWidgets('Samsung refusal explains WAL and one tap opens saved server account, with no promotion', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('foto24-view-widget-')))!;
    addTearDown(() => directory.delete(recursive: true));
    final server = (await tester.runAsync(RecoveryHttpServer.start))!;
    addTearDown(server.close);
    final source = (await tester.runAsync(
      () => createAccountRecoveryFixture(directory, checkpoint: true, endpoint: server.endpoint),
    ))!;
    final probe = sqlite3.open(source.path, mode: OpenMode.readOnly);
    probe.select('PRAGMA quick_check(1)');
    probe.close();
    final before = (await tester.runAsync(() => recoveryFileHashes(source)))!;
    final host = FileRecoveryHost(source, Directory('${directory.path}/recovery'));
    var opened = 0;
    final recoveryDone = Completer<void>();
    final serverReady = Completer<void>();
    await tester.pumpWidget(
      localized(
        SqliteRecoveryPage(
          recoverAndOpen: () async {
            RecoveryRefused? refusal;
            await tester.runAsync(() async {
              try {
                await OneTapSqliteRecovery(host).run();
              } on RecoveryRefused catch (error) {
                refusal = error;
              }
            });
            recoveryDone.complete();
            if (refusal != null) {
              throw refusal!;
            }
          },
          exportBackup: () async => true,
          openServerPhotos: () async {
            opened++;
            final credentials = (await tester.runAsync(() => captureRecoveryServerCredentials(host)))!;
            serverReady.complete();
            return HttpOverrides.runWithHttpOverrides(() => RecoveryServerClient(credentials), _RealHttpOverrides());
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(opened, 0);
    await tester.tap(find.text('Восстановить и открыть FOTO'));
    await recoveryDone.future;
    for (var i = 0; i < 100 && find.textContaining('empty_wal_evidence_missing').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.textContaining('empty_wal_evidence_missing'), findsOneWidget);
    await tester.tap(find.text('Открыть серверные фотографии'));
    await serverReady.future;
    for (
      var i = 0;
      i < 100 && find.byKey(const ValueKey('server-photo-${RecoveryHttpServer.photoId}')).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Серверные фотографии'), findsOneWidget);
    expect(find.text('Existing owner'), findsOneWidget);
    expect(find.byKey(const ValueKey('server-photo-${RecoveryHttpServer.photoId}')), findsOneWidget);
    expect(opened, 1);
    expect(host.blocked, true);
    expect(host.selection.existsSync(), false);
    expect(await tester.runAsync(() => recoveryFileHashes(source)), before);
    expect(server.requests.every((r) => r.method == 'GET' && r.authenticated), true);
    await tester.pumpWidget(const SizedBox());
  });
}
