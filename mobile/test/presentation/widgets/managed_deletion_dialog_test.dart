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
  });
  Future<void> open(WidgetTester tester) async {
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
              home: const Scaffold(body: ManagedDeletionDialog()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows Russian managed-only explanation on a narrow high-DPI screen', (tester) async {
    await open(tester);
    expect(find.text('Разрешение окончательного удаления'), findsOneWidget);
    expect(find.textContaining('Внешние библиотеки защищены отдельно'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
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
    expect(find.textContaining('Администратор должен сначала'), findsOneWidget);
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
  ]) {
    testWidgets('localizes $code after a rejected signed-evidence preparation', (tester) async {
      when(
        () => repository.managedDeletionStatus(),
      ).thenAnswer((_) async => const ManagedDeletionStatus(enabled: false, prepared: false, canPrepare: true));
      when(() => repository.prepareManagedDeletion(any())).thenThrow(ApiException(409, '{"message":"$code"}'));
      await open(tester);
      final context = tester.element(find.byType(ManagedDeletionDialog));
      expect(find.text(context.t.managed_deletion_recovery_help), findsOneWidget);
      await tester.enterText(find.byType(TextField), List.filled(64, 'a').join());
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      final prepare = find.widgetWithText(OutlinedButton, context.t.managed_deletion_prepare);
      await tester.ensureVisible(prepare);
      await tester.tap(prepare);
      await tester.pumpAndSettle();
      final result = PermanentDeletionResult(id: 'fixture', state: 'blocked', code: code);
      expect(find.text(deletionMessage(context, result)), findsOneWidget);
      expect(find.textContaining(code), findsNothing);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
      verifyNever(() => repository.setManagedDeletionConsent(any()));
      expect(tester.takeException(), isNull);
    });
  }
}
