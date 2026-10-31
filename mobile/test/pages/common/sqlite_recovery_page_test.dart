import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/sqlite_fresh_start.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/pages/common/sqlite_recovery.page.dart';
import 'package:immich_mobile/utils/app_asset_loader.dart';
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
    expect(find.text('Экспортировать резервную копию'), findsOneWidget);
    expect(find.text('Восстановить и открыть FOTO'), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    await completed.future;
    expect(await completed.future, 'existing-owner');
    expect(taps, 1);
    await tester.pumpAndSettle();
  });
  testWidgets('a second tap cannot start concurrent recovery', (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      localized(
        SqliteRecoveryPage(
          recoverAndOpen: () async {
            calls++;
            await pending.future;
          },
          exportBackup: () async => false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.tap(find.byType(FilledButton));
    expect(calls, 1);
    pending.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.tap(find.byType(FilledButton));
    expect(calls, 1);
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
  testWidgets('fresh start requires verified export, unchecked loss consent and a separate confirmation', (
    tester,
  ) async {
    var exported = 0;
    var restarted = 0;
    await tester.pumpWidget(
      localized(
        SqliteRecoveryPage(
          recoverAndOpen: () async {},
          exportBackup: () async => false,
          prepareFreshStart: () async {
            exported++;
            return const FreshStartPreparation(VerifiedRecoveryExport('native-proof', 'test-zip-hash'));
          },
          startFreshAndOpen: (_) async {
            restarted++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Начать заново с серверными фотографиями'));
    await tester.pumpAndSettle();
    expect(exported, 1);
    expect(restarted, 0);
    final confirmation = find.widgetWithText(FilledButton, 'Создать новую локальную библиотеку');
    expect(tester.widget<FilledButton>(confirmation).onPressed, isNull);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(confirmation);
    await tester.pumpAndSettle();
    expect(restarted, 1);
  });

  testWidgets('cancelling external export never shows loss consent or creates a fresh database', (tester) async {
    var restarted = 0;
    await tester.pumpWidget(
      localized(
        SqliteRecoveryPage(
          recoverAndOpen: () async {},
          exportBackup: () async => false,
          prepareFreshStart: () async => null,
          startFreshAndOpen: (_) async {
            restarted++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Начать заново с серверными фотографиями'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(restarted, 0);
  });
}
