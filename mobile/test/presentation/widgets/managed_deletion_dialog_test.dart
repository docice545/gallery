import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/managed_deletion_dialog.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/utils/deletion_message.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

class _Repository extends Mock implements AssetApiRepository {}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
  });
  late _Repository repository;
  setUp(() {
    repository = _Repository();
    when(
      () => repository.managedDeletionStatus(),
    ).thenAnswer((_) async => const ManagedDeletionStatus(enabled: false, prepared: true, canPrepare: false));
    when(() => repository.setManagedDeletionConsent(any())).thenAnswer((_) async {});
    when(() => repository.libraryDeletionScopes()).thenAnswer(
      (_) async => [
        {'scope': 'own-library-a', 'name': 'Моя библиотека', 'count': 0, 'authorized': false},
        {'scope': 'own-library-b', 'name': 'Другая библиотека', 'count': 3, 'authorized': false},
      ],
    );
    when(
      () => repository.libraryDeletionStatus(any()),
    ).thenAnswer((_) async => const ManagedDeletionStatus(enabled: false, prepared: true, canPrepare: false));
    when(() => repository.setLibraryDeletionConsent(any(), any())).thenAnswer((_) async {});
  });
  Future<void> open(WidgetTester tester, {bool external = false, bool settle = true}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [assetApiRepositoryProvider.overrideWithValue(repository)],
        child: EasyLocalization(
          supportedLocales: const [Locale('ru')],
          startLocale: const Locale('ru'),
          fallbackLocale: const Locale('ru'),
          path: '../i18n',
          assetLoader: const CodegenLoader(),
          child: Builder(
            builder: (context) => MaterialApp(
              locale: context.locale,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              home: Scaffold(body: ManagedDeletionDialog(external: external)),
            ),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('shows Russian managed-only explanation on a narrow high-DPI screen', (tester) async {
    await open(tester);
    expect(find.text('Разрешение окончательного удаления'), findsOneWidget);
    expect(find.textContaining('Внешние библиотеки защищены отдельно'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('external consent is explicit and affects only the selected owner library', (tester) async {
    await open(tester, external: true);
    final context = tester.element(find.byType(ManagedDeletionDialog));
    expect(find.textContaining('Моя библиотека'), findsOneWidget);
    final enable = find.widgetWithText(FilledButton, context.t.external_deletion_enable);
    await tester.ensureVisible(enable);
    await tester.tap(enable);
    await tester.pumpAndSettle();
    verifyNever(() => repository.setLibraryDeletionConsent(any(), any()));
    expect(find.text(context.t.external_deletion_confirm), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, context.t.external_deletion_enable));
    await tester.pumpAndSettle();
    verify(() => repository.setLibraryDeletionConsent('own-library-a', true)).called(1);
    verifyNever(() => repository.setLibraryDeletionConsent('own-library-b', any()));
    verifyNever(() => repository.setManagedDeletionConsent(any()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('external library remains revocable with zero Trash assets and unavailable evidence', (tester) async {
    when(
      () => repository.libraryDeletionStatus(any()),
    ).thenAnswer((_) async => const ManagedDeletionStatus(enabled: true, prepared: false, canPrepare: false));
    await open(tester, external: true);
    final context = tester.element(find.byType(ManagedDeletionDialog));
    final revoke = find.widgetWithText(FilledButton, context.t.managed_deletion_disable);
    await tester.ensureVisible(revoke);
    await tester.tap(revoke);
    await tester.pumpAndSettle();
    verify(() => repository.setLibraryDeletionConsent('own-library-a', false)).called(1);
    verifyNever(() => repository.prepareLibraryDeletion(any(), any()));
    verifyNever(() => repository.setManagedDeletionConsent(any()));
  });

  testWidgets('empty owned library list has no authorization action or perpetual spinner', (tester) async {
    when(() => repository.libraryDeletionScopes()).thenAnswer((_) async => []);
    await open(tester, external: true);
    final context = tester.element(find.byType(ManagedDeletionDialog));
    expect(find.text(context.t.external_deletion_empty), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    verifyNever(() => repository.libraryDeletionStatus(any()));
  });

  testWidgets('changed library cannot reuse the previous verified status or proof', (tester) async {
    when(
      () => repository.libraryDeletionStatus('own-library-b'),
    ).thenAnswer((_) async => const ManagedDeletionStatus(enabled: false, prepared: false, canPrepare: false));
    await open(tester, external: true);
    await tester.ensureVisible(find.byType(DropdownButton<String>));
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Другая библиотека').last);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    verify(() => repository.libraryDeletionStatus('own-library-b')).called(1);
    verifyNever(() => repository.setLibraryDeletionConsent(any(), any()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('late status from another library cannot enable the selected unprepared library', (tester) async {
    final oldStatus = Completer<ManagedDeletionStatus>();
    when(() => repository.libraryDeletionStatus('own-library-a')).thenAnswer((_) => oldStatus.future);
    when(
      () => repository.libraryDeletionStatus('own-library-b'),
    ).thenAnswer((_) async => const ManagedDeletionStatus(enabled: false, prepared: false, canPrepare: false));
    await open(tester, external: true, settle: false);
    await tester.pump();
    // Do not wait for the still-pending request's progress indicator to settle.
    await tester.ensureVisible(find.byType(DropdownButton<String>));
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.textContaining('Другая библиотека').last);
    await tester.pumpAndSettle();
    oldStatus.complete(const ManagedDeletionStatus(enabled: true, prepared: true, canPrepare: false));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    verifyNever(() => repository.setLibraryDeletionConsent(any(), any()));
    expect(tester.takeException(), isNull);
  });
  testWidgets('ordinary managed storage is usable without recovery proof or administrator preparation', (tester) async {
    when(
      () => repository.managedDeletionStatus(),
    ).thenAnswer((_) async => const ManagedDeletionStatus(enabled: true, prepared: true, canPrepare: false));
    await open(tester);
    final context = tester.element(find.byType(ManagedDeletionDialog));
    expect(find.text(context.t.managed_deletion_enabled), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    verifyNever(() => repository.prepareManagedDeletion(any()));
  });

  testWidgets('does not authorize before a separate confirmation', (tester) async {
    await open(tester);
    final enable = find.widgetWithText(FilledButton, 'Разрешить удаление из управляемого хранилища');
    await tester.ensureVisible(enable);
    await tester.tap(enable);
    await tester.pumpAndSettle();
    verifyNever(() => repository.setManagedDeletionConsent(any()));
    expect(find.textContaining('Разрешить необратимое удаление'), findsOneWidget);
  });
  testWidgets('unprepared storage cannot be enabled', (tester) async {
    when(
      () => repository.managedDeletionStatus(),
    ).thenAnswer((_) async => const ManagedDeletionStatus(enabled: false, prepared: false, canPrepare: false));
    await open(tester);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.textContaining('недоступно для безопасного удаления'), findsOneWidget);
  });
  testWidgets('owner can revoke without confirmation and no filesystem preparation', (tester) async {
    when(
      () => repository.managedDeletionStatus(),
    ).thenAnswer((_) async => const ManagedDeletionStatus(enabled: true, prepared: true, canPrepare: false));
    await open(tester);
    final revoke = find.widgetWithText(FilledButton, 'Отозвать разрешение');
    await tester.ensureVisible(revoke);
    await tester.tap(revoke);
    await tester.pumpAndSettle();
    verify(() => repository.setManagedDeletionConsent(false)).called(1);
    verifyNever(() => repository.prepareManagedDeletion(any()));
  });

  testWidgets('owner can still revoke when signed evidence is no longer prepared', (tester) async {
    when(
      () => repository.managedDeletionStatus(),
    ).thenAnswer((_) async => const ManagedDeletionStatus(enabled: true, prepared: false, canPrepare: false));
    await open(tester);
    final context = tester.element(find.byType(ManagedDeletionDialog));
    expect(find.text(context.t.managed_deletion_preparation_required), findsOneWidget);
    expect(find.text(context.t.managed_deletion_enabled), findsNothing);
    final revoke = find.widgetWithText(FilledButton, context.t.managed_deletion_disable);
    await tester.ensureVisible(revoke);
    await tester.tap(revoke);
    await tester.pumpAndSettle();
    verify(() => repository.setManagedDeletionConsent(false)).called(1);
  });

  testWidgets('refreshes expired preparation after failed consent and preserves the localized error', (tester) async {
    var loads = 0;
    when(
      () => repository.managedDeletionStatus(),
    ).thenAnswer((_) async => ManagedDeletionStatus(enabled: false, prepared: loads++ == 0, canPrepare: false));
    when(
      () => repository.setManagedDeletionConsent(true),
    ).thenThrow(ApiException(409, '{"message":"DELETION_RECOVERY_EXPIRED"}'));
    await open(tester);
    final context = tester.element(find.byType(ManagedDeletionDialog));
    final enable = find.widgetWithText(FilledButton, context.t.managed_deletion_enable);
    await tester.ensureVisible(enable);
    await tester.tap(enable);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, context.t.managed_deletion_enable));
    await tester.pumpAndSettle();
    expect(find.text(context.t.managed_deletion_recovery_expired), findsOneWidget);
    expect(find.text(context.t.managed_deletion_preparation_required), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    verify(() => repository.managedDeletionStatus()).called(2);
    verify(() => repository.setManagedDeletionConsent(true)).called(1);
  });

  for (final code in [
    'DELETION_RECOVERY_UNAVAILABLE',
    'DELETION_RECOVERY_INVALID',
    'DELETION_RECOVERY_EXPIRED',
    'DELETION_RECOVERY_SCOPE_MISMATCH',
    'DELETION_ROOT_CHANGED',
    'OVERLAPPING_OWNER_ROOTS',
    'UNSUPPORTED_DELETION_FILESYSTEM',
    'DELETION_QUARANTINE_CONFLICT',
    'LIBRARY_STORAGE_READ_ONLY',
  ]) {
    testWidgets('localizes $code from a previous-server consent failure without proof inputs', (tester) async {
      when(
        () => repository.managedDeletionStatus(),
      ).thenAnswer((_) async => const ManagedDeletionStatus(enabled: false, prepared: true, canPrepare: true));
      when(() => repository.setManagedDeletionConsent(true)).thenThrow(ApiException(409, '{"message":"$code"}'));
      await open(tester);
      final context = tester.element(find.byType(ManagedDeletionDialog));
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      final enable = find.widgetWithText(FilledButton, context.t.managed_deletion_enable);
      await tester.ensureVisible(enable);
      await tester.tap(enable);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, context.t.managed_deletion_enable));
      await tester.pumpAndSettle();
      final result = PermanentDeletionResult(id: 'fixture', state: 'blocked', code: code);
      expect(find.text(deletionMessage(context, result)), findsOneWidget);
      expect(find.textContaining(code), findsNothing);
      verify(() => repository.setManagedDeletionConsent(true)).called(1);
      verifyNever(() => repository.prepareManagedDeletion(any()));
      expect(tester.takeException(), isNull);
    });
  }
}
