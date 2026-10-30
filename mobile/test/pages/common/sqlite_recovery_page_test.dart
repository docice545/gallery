import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/pages/common/sqlite_recovery.page.dart';
import 'package:immich_mobile/utils/app_asset_loader.dart';
// easy_localization uses this transitive plugin during initialization.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../data/db/sqlite_one_tap_recovery_test.dart' show FileRecoveryHost, createRecoveryFixture;

Widget localized(Widget child) => EasyLocalization(
  supportedLocales: const [Locale('ru')],
  startLocale: const Locale('ru'),
  fallbackLocale: const Locale('ru'),
  path: '../i18n',
  assetLoader: const AppAssetLoader(),
  child: child,
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  testWidgets('Russian screen waits for one tap and returns the existing account from real WAL recovery', (
    tester,
  ) async {
    final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('foto23-widget-')))!;
    addTearDown(() => directory.delete(recursive: true));
    final source = (await tester.runAsync(() => createRecoveryFixture(directory)))!;
    final host = FileRecoveryHost(source, Directory('${directory.path}/recovery'));
    var taps = 0;
    final started = Completer<void>();
    final completed = Completer<String>();
    await tester.pumpWidget(
      localized(
        SqliteRecoveryPage(
          recoverAndOpen: () async {
            await tester.runAsync(() async {
              taps++;
              started.complete();
              try {
                await OneTapSqliteRecovery(host).run();
                final db = sqlite3.open(host.selected.path);
                try {
                  completed.complete(
                    db.select("SELECT value FROM settings WHERE key='account'").single.values.single! as String,
                  );
                } finally {
                  db.close();
                }
              } catch (error, stack) {
                completed.completeError(error, stack);
                rethrow;
              }
            });
          },
          exportBackup: () async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(find.text('Требуется восстановление FOTO'), findsOneWidget);
    expect(find.text('Восстановить и открыть FOTO'), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    await completed.future;
    expect(await completed.future, 'existing-owner');
    expect(taps, 1);
    await tester.pumpAndSettle();
  });
  testWidgets('failure preserves screen and exposes system-export action', (tester) async {
    var exported = 0;
    await tester.pumpWidget(
      localized(
        SqliteRecoveryPage(
          recoverAndOpen: () async => throw StateError('unsafe WAL'),
          exportBackup: () async {
            exported++;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('Автоматическое восстановление не удалось. Ваши исходные данные сохранены'), findsOneWidget);
    await tester.tap(find.text('Экспортировать резервную копию'));
    await tester.pumpAndSettle();
    expect(exported, 1);
    expect(find.text('Требуется восстановление FOTO'), findsOneWidget);
  });
}
