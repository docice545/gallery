import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/managed_deletion_dialog.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:mocktail/mocktail.dart';

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
    await tester.tap(find.text('Разрешить удаление из managed storage'));
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
    await tester.tap(find.text('Отозвать разрешение'));
    await tester.pumpAndSettle();
    verify(() => repository.setManagedDeletionConsent(false)).called(1);
    verifyNever(() => repository.prepareManagedDeletion(any()));
  });
}
