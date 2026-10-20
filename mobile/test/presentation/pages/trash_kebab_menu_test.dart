import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/trash.page.dart';
import 'package:immich_mobile/presentation/widgets/managed_deletion_dialog.dart';
import 'package:immich_mobile/providers/infrastructure/action.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:mocktail/mocktail.dart';

class _ServerInfoService extends Mock implements ServerInfoService {}

class _AssetService extends Mock implements AssetService {}

class _AssetApiRepository extends Mock implements AssetApiRepository {}

class _ActionNotifier extends ActionNotifier {
  var restoreCalls = 0;

  @override
  void build() {}

  @override
  Future<ActionResult> restoreAllTrash(String userId) async {
    restoreCalls++;
    return const ActionResult(count: 0, success: true);
  }
}

void main() {
  late BuildContext testContext;
  late _AssetService assets;
  late _AssetApiRepository repository;
  late _ActionNotifier actions;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
  });

  setUp(() {
    assets = _AssetService();
    repository = _AssetApiRepository();
    actions = _ActionNotifier();
    when(
      () => repository.managedDeletionStatus(),
    ).thenAnswer((_) async => const ManagedDeletionStatus(enabled: false, prepared: true, canPrepare: false));
    when(() => repository.libraryDeletionScopes()).thenAnswer((_) async => []);
  });

  Future<void> pumpMenu(
    WidgetTester tester, {
    double width = 360,
    double height = 780,
    double textScale = 1.0,
    EdgeInsets padding = EdgeInsets.zero,
    bool safeArea = false,
    bool authorizedDeletion = true,
  }) async {
    tester.view.physicalSize = Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = FakeViewPadding(
      left: padding.left * 3,
      top: padding.top * 3,
      right: padding.right * 3,
      bottom: padding.bottom * 3,
    );
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          assetServiceProvider.overrideWithValue(assets),
          assetApiRepositoryProvider.overrideWithValue(repository),
          actionProvider.overrideWith(() => actions),
          serverInfoProvider.overrideWith((ref) {
            final notifier = ServerInfoNotifier(_ServerInfoService());
            notifier.state = notifier.state.copyWith(
              serverFeatures: notifier.state.serverFeatures.copyWith(authorizedDeletion: authorizedDeletion),
            );
            return notifier;
          }),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('ru')],
          startLocale: const Locale('ru'),
          fallbackLocale: const Locale('ru'),
          path: '../i18n',
          assetLoader: const CodegenLoader(),
          child: Builder(
            builder: (context) => MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              locale: context.locale,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              home: Builder(
                builder: (context) {
                  testContext = context;
                  final scaffold = Scaffold(appBar: AppBar(actions: const [TrashKebabMenu()]));
                  return safeArea ? SafeArea(child: scaffold) : scaffold;
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
  }

  for (final scenario in [
    (name: 'narrow', width: 320.0, height: 600.0, padding: EdgeInsets.zero, safeArea: false),
    (
      name: 'S23 dimensions',
      width: 360.0,
      height: 780.0,
      padding: const EdgeInsets.only(top: 24, bottom: 24),
      safeArea: false,
    ),
    (
      name: 'consumed SafeArea',
      width: 320.0,
      height: 600.0,
      padding: const EdgeInsets.fromLTRB(24, 24, 16, 24),
      safeArea: true,
    ),
    (name: 'landscape', width: 780.0, height: 360.0, padding: const EdgeInsets.fromLTRB(48, 0, 24, 24), safeArea: true),
    (name: 'wide', width: 900.0, height: 700.0, padding: EdgeInsets.zero, safeArea: false),
  ]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('Russian labels remain fully visible: ${scenario.name}, text scale $scale', (tester) async {
        await pumpMenu(
          tester,
          width: scenario.width,
          height: scenario.height,
          textScale: scale,
          padding: scenario.padding,
          safeArea: scenario.safeArea,
        );

        final labels = [
          testContext.t.managed_deletion_title,
          testContext.t.empty_trash,
          testContext.t.external_deletion_title,
          testContext.t.restore_all,
        ];
        final buttons = tester.widgetList<MenuItemButton>(find.byType(MenuItemButton)).toList();
        expect(buttons.map((button) => (button.child! as Text).data), labels);
        expect(buttons.map((button) => (button.leadingIcon! as Icon).icon), [
          Icons.shield_outlined,
          Icons.delete_forever_outlined,
          Icons.folder_delete_outlined,
          Icons.restore_outlined,
        ]);

        for (final label in labels) {
          final text = find.text(label);
          await tester.ensureVisible(text);
          await tester.pumpAndSettle();
          final paragraph = tester.renderObject<RenderParagraph>(text);
          expect(paragraph.text.toPlainText(), label);
          expect(paragraph.didExceedMaxLines, isFalse);
          expect(paragraph.maxLines, isNull);
          expect(paragraph.overflow, isNot(TextOverflow.ellipsis));
          expect(paragraph.textScaler.scale(15), closeTo(15 * scale, 0.01));
          // A selection of an entire line includes trailing spaces beyond its
          // wrap edge. Check every visible glyph, excluding that whitespace.
          final boxes = RegExp(r'\S+')
              .allMatches(label)
              .expand(
                (word) => paragraph.getBoxesForSelection(TextSelection(baseOffset: word.start, extentOffset: word.end)),
              )
              .toList();
          expect(boxes, isNotEmpty);
          for (final box in boxes) {
            expect(box.left, greaterThanOrEqualTo(-0.01));
            expect(box.right, lessThanOrEqualTo(paragraph.size.width + 0.01));
            expect(box.top, greaterThanOrEqualTo(-0.01));
            expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + 0.01));
          }
          if (label == testContext.t.external_deletion_title) {
            expect(
              boxes.map((box) => box.top).toSet().length,
              greaterThan(1),
              reason: 'The complete permission title must wrap',
            );
          }
          final item = find.ancestor(of: text, matching: find.byType(MenuItemButton));
          final itemRect = tester.getRect(item);
          final textRect = tester.getRect(text);
          expect(itemRect.width, lessThanOrEqualTo(400));
          expect(itemRect.left, greaterThanOrEqualTo(scenario.padding.left));
          expect(itemRect.right, lessThanOrEqualTo(scenario.width - scenario.padding.right));
          expect(textRect.top, greaterThanOrEqualTo(scenario.padding.top));
          expect(textRect.bottom, lessThanOrEqualTo(scenario.height - scenario.padding.bottom));
          expect(itemRect.contains(textRect.topLeft), isTrue);
          expect(itemRect.contains(textRect.bottomRight - const Offset(0.01, 0.01)), isTrue);
          expect(text.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        verifyZeroInteractions(assets);
        verifyZeroInteractions(repository);
      });
    }
  }

  testWidgets('server without authorized deletion only shows empty and restore', (tester) async {
    await pumpMenu(tester, authorizedDeletion: false);
    expect(find.byType(MenuItemButton), findsNWidgets(2));
    expect(find.text(testContext.t.empty_trash), findsOneWidget);
    expect(find.text(testContext.t.restore_all), findsOneWidget);
    expect(find.text(testContext.t.managed_deletion_title), findsNothing);
    expect(find.text(testContext.t.external_deletion_title), findsNothing);
    verifyZeroInteractions(assets);
    verifyZeroInteractions(repository);
  });

  for (final external in [false, true]) {
    testWidgets('permission action opens the existing dialog (external: $external) without consent', (tester) async {
      await pumpMenu(tester);
      final label = external ? testContext.t.external_deletion_title : testContext.t.managed_deletion_title;
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(tester.widget<ManagedDeletionDialog>(find.byType(ManagedDeletionDialog)).external, external);
      expect(find.byType(MenuItemButton), findsNothing);
      if (external) {
        verify(() => repository.libraryDeletionScopes()).called(1);
        verifyNever(() => repository.managedDeletionStatus());
      } else {
        verify(() => repository.managedDeletionStatus()).called(1);
        verifyNever(() => repository.libraryDeletionScopes());
      }
      verifyNever(() => repository.setManagedDeletionConsent(any()));
      verifyNever(() => repository.setLibraryDeletionConsent(any(), any()));
      verifyZeroInteractions(assets);
      expect(tester.takeException(), isNull);
    });
  }

  for (final restore in [false, true]) {
    testWidgets('${restore ? 'restore' : 'empty'} action requires confirmation and cancellation does nothing', (
      tester,
    ) async {
      await pumpMenu(tester);
      final label = restore ? testContext.t.restore_all : testContext.t.empty_trash;
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmDialog), findsOneWidget);
      expect(
        find.text(restore ? testContext.t.assets_restore_confirmation : testContext.t.empty_trash_confirmation),
        findsOneWidget,
      );
      expect(find.byType(MenuItemButton), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, testContext.t.cancel));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmDialog), findsNothing);
      expect(actions.restoreCalls, 0);
      verifyZeroInteractions(assets);
      verifyZeroInteractions(repository);
      expect(tester.takeException(), isNull);
    });
  }
}
