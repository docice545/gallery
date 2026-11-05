import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/trash.page.dart';
import 'package:immich_mobile/providers/infrastructure/action.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:mocktail/mocktail.dart';

class _Assets extends Mock implements AssetService {}

class _Users extends Mock implements UserService {}

class _ServerInfo extends Mock implements ServerInfoService {}

class _Toasts extends Mock implements ToastService {}

class _Cleanup extends Mock implements CleanupService {}

class _Actions extends ActionNotifier {
  @override
  void build() {}

  @override
  Future<ActionResult> restoreAllTrash(String userId) async => const ActionResult(count: 0, success: true);
}

void main() {
  late _Assets assets;
  late _Users users;
  late _Toasts toasts;
  late _Cleanup cleanup;
  late ValueNotifier<List<String>> visibleIds;
  late BuildContext pageContext;
  var continueCalls = 0;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(<String>[]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
  });

  setUp(() {
    EasyLocalization.logger.enableBuildModes = [];
    assets = _Assets();
    users = _Users();
    toasts = _Toasts();
    cleanup = _Cleanup();
    continueCalls = 0;
    visibleIds = ValueNotifier(['still', 'video']);
    final owner = UserDto(id: 'owner', email: 'owner@example.test', name: 'Owner', profileChangedAt: DateTime(2026));
    when(() => users.tryGetMyUser()).thenReturn(owner);
    when(() => users.watchMyUser()).thenAnswer((_) => const Stream.empty());
    when(() => assets.getTrashIds('owner')).thenAnswer((_) async => List.of(visibleIds.value));
  });

  Future<void> pumpPage(WidgetTester tester, {bool openMenu = true}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          assetServiceProvider.overrideWithValue(assets),
          userServiceProvider.overrideWithValue(users),
          toastServiceProvider.overrideWithValue(toasts),
          cleanupServiceProvider.overrideWithValue(cleanup),
          actionProvider.overrideWith(_Actions.new),
          serverInfoProvider.overrideWith((ref) {
            final notifier = ServerInfoNotifier(_ServerInfo());
            notifier.state = notifier.state.copyWith(
              serverFeatures: notifier.state.serverFeatures.copyWith(authorizedDeletion: false),
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
              locale: context.locale,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              home: Builder(
                builder: (context) {
                  pageContext = context;
                  return Scaffold(
                    appBar: AppBar(actions: const [TrashKebabMenu()]),
                    // This small reactive fixture models the service's cache
                    // publication only. Durable SQLite/replay is tested with
                    // the real repositories in instant_trash_acceptance_test.
                    body: ValueListenableBuilder<List<String>>(
                      valueListenable: visibleIds,
                      builder: (context, ids, _) => Column(
                        children: [
                          if (ids.isEmpty)
                            const Text('synthetic empty trash', key: Key('test-empty-trash'))
                          else
                            for (final id in ids) Text(id, key: Key('test-trash-$id')),
                          TextButton(
                            key: const Key('test-continue'),
                            onPressed: () => continueCalls++,
                            child: const Text('Continue'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (openMenu) {
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
    }
  }

  Future<void> confirmEmpty(WidgetTester tester) async {
    await tester.tap(find.text(pageContext.t.empty_trash));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmDialog), findsOneWidget);
    expect(find.text(pageContext.t.empty_trash_confirmation), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, pageContext.t.delete_permanently));
    await tester.pumpAndSettle();
  }

  void publishAccepted(List<PermanentDeletionResult> results) {
    final accepted = results.where((result) => result.accepted).map((result) => result.id).toSet();
    visibleIds.value = visibleIds.value.where((id) => !accepted.contains(id)).toList();
  }

  List<PermanentDeletionResult> acceptedPending() => const [
    PermanentDeletionResult(id: 'still', state: 'pending', serverAccepted: true),
    PermanentDeletionResult(id: 'video', state: 'pending', serverAccepted: true),
  ];

  testWidgets('Build29 shows empty Trash and green success only after durable acceptance, without worker polling', (
    tester,
  ) async {
    final accepted = Completer<List<PermanentDeletionResult>>();
    when(() => assets.acceptPermanentDeletion(any())).thenAnswer((_) async {
      final result = await accepted.future;
      publishAccepted(result);
      return result;
    });
    await pumpPage(tester);
    await confirmEmpty(tester);

    expect(find.byKey(const Key('test-trash-still')), findsOneWidget);
    expect(find.byKey(const Key('test-trash-video')), findsOneWidget);
    expect(find.byKey(const Key('test-empty-trash')), findsNothing);
    expect(find.byType(BatchDeletionDialog), findsNothing);
    verifyNever(() => toasts.success(any(), toast: any(named: 'toast')));
    verifyNever(() => toasts.error(any(), toast: any(named: 'toast')));
    verifyZeroInteractions(cleanup);

    // The server's physical worker remains pending; only irreversible
    // acceptance is necessary for the synchronous user-facing operation.
    accepted.complete(acceptedPending());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('test-empty-trash')), findsOneWidget);
    expect(find.byKey(const Key('test-trash-still')), findsNothing);
    expect(find.byType(BatchDeletionDialog), findsNothing);
    verify(() => toasts.success(pageContext.t.trash_cleanup_accepted)).called(1);
    verifyNever(() => toasts.error(any(), toast: any(named: 'toast')));
    verify(() => assets.acceptPermanentDeletion(['still', 'video'])).called(1);
    verifyNever(() => assets.deleteWithResults(any(), onBatchStatus: any(named: 'onBatchStatus')));
    verifyZeroInteractions(cleanup);
    await tester.tap(find.byKey(const Key('test-continue')));
    expect(continueCalls, 1);
    expect(tester.takeException(), isNull);

    // A new UI instance reads the already-published cache; it must not revive
    // the accepted rows or restart physical deletion.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await pumpPage(tester, openMenu: false);
    expect(find.byKey(const Key('test-empty-trash')), findsOneWidget);
    verifyNever(() => assets.acceptPermanentDeletion(any()));
    verifyZeroInteractions(cleanup);
  });

  testWidgets('Build29 repeated clicks while acceptance is pending cannot submit a second clear operation', (
    tester,
  ) async {
    final accepted = Completer<List<PermanentDeletionResult>>();
    when(() => assets.acceptPermanentDeletion(any())).thenAnswer((_) => accepted.future);
    await pumpPage(tester);
    await confirmEmpty(tester);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    final empty = find.ancestor(of: find.text(pageContext.t.empty_trash), matching: find.byType(MenuItemButton));
    expect(tester.widget<MenuItemButton>(empty).onPressed, isNull);
    await tester.tap(empty);
    await tester.pump();
    verify(() => assets.acceptPermanentDeletion(['still', 'video'])).called(1);
    verifyNever(() => toasts.success(any(), toast: any(named: 'toast')));
    accepted.complete(acceptedPending());
    await tester.pumpAndSettle();
    verifyNever(() => assets.acceptPermanentDeletion(any()));
    verifyZeroInteractions(cleanup);
    expect(tester.takeException(), isNull);
  });

  for (final (state, code) in [
    ('blocked', 'REQUEST_REJECTED'),
    ('blocked', 'REQUEST_NOT_SENT'),
    ('uncertain', 'REQUEST_OUTCOME_UNKNOWN'),
    ('pending', 'DELETION_BATCH_QUEUED'),
  ]) {
    testWidgets('Build29 $state/$code keeps Trash visible and never reports successful acceptance', (tester) async {
      when(() => assets.acceptPermanentDeletion(any())).thenAnswer(
        (_) async => [
          PermanentDeletionResult(id: 'still', state: state, code: code),
          PermanentDeletionResult(id: 'video', state: state, code: code),
        ],
      );
      await pumpPage(tester);
      await confirmEmpty(tester);
      expect(find.byKey(const Key('test-empty-trash')), findsNothing);
      expect(find.byKey(const Key('test-trash-still')), findsOneWidget);
      expect(find.byKey(const Key('test-trash-video')), findsOneWidget);
      verifyNever(() => toasts.success(any(), toast: any(named: 'toast')));
      verify(() => toasts.error(any(), toast: any(named: 'toast'))).called(1);
      verifyZeroInteractions(cleanup);
      expect(find.byType(BatchDeletionDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Build29 accepted physical failure stays outside user Trash while blocked items remain', (tester) async {
    const results = [
      PermanentDeletionResult(id: 'still', state: 'failed', serverAccepted: true, code: 'DELETION_STORAGE_ERROR'),
      PermanentDeletionResult(id: 'video', state: 'blocked', code: 'REQUEST_REJECTED'),
    ];
    when(() => assets.acceptPermanentDeletion(any())).thenAnswer((_) async {
      publishAccepted(results);
      return results;
    });
    await pumpPage(tester);
    await confirmEmpty(tester);
    expect(find.byKey(const Key('test-trash-still')), findsNothing);
    expect(find.byKey(const Key('test-trash-video')), findsOneWidget);
    verifyNever(() => toasts.success(any(), toast: any(named: 'toast')));
    verify(() => toasts.error(any(), toast: any(named: 'toast'))).called(1);
    verifyZeroInteractions(cleanup);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Build29 a newly trashed asset outside the confirmed snapshot is never hidden', (tester) async {
    final accepted = Completer<List<PermanentDeletionResult>>();
    when(() => assets.acceptPermanentDeletion(any())).thenAnswer((_) async {
      final result = await accepted.future;
      publishAccepted(result);
      return result;
    });
    await pumpPage(tester);
    await confirmEmpty(tester);
    visibleIds.value = [...visibleIds.value, 'new-trash'];
    accepted.complete(acceptedPending());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('test-trash-still')), findsNothing);
    expect(find.byKey(const Key('test-trash-video')), findsNothing);
    expect(find.byKey(const Key('test-trash-new-trash')), findsOneWidget);
    verify(() => assets.acceptPermanentDeletion(['still', 'video'])).called(1);
    verifyZeroInteractions(cleanup);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Build29 navigating away during acceptance does not cancel it or use a disposed context', (tester) async {
    final accepted = Completer<List<PermanentDeletionResult>>();
    when(() => assets.acceptPermanentDeletion(any())).thenAnswer((_) async {
      final result = await accepted.future;
      publishAccepted(result);
      return result;
    });
    await pumpPage(tester);
    await confirmEmpty(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    accepted.complete(acceptedPending());
    await tester.pumpAndSettle();
    expect(visibleIds.value, isEmpty);
    verifyNever(() => toasts.success(any(), toast: any(named: 'toast')));
    verifyNever(() => toasts.error(any(), toast: any(named: 'toast')));
    verifyZeroInteractions(cleanup);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Build29 cancelling the confirmation never captures or sends a deletion', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text(pageContext.t.empty_trash));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, pageContext.t.cancel));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('test-trash-still')), findsOneWidget);
    verifyZeroInteractions(assets);
    verifyZeroInteractions(toasts);
    verifyZeroInteractions(cleanup);
    expect(tester.takeException(), isNull);
  });
}
