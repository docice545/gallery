import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/restore.action.dart';
import 'package:immich_mobile/presentation/pages/trash.page.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/utils/asset_filter.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../service.mocks.dart';
import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

void main() {
  late PresentationContext fixture;
  late MockAssetService service;
  late MockToastService toasts;

  setUp(() async {
    fixture = await PresentationContext.create();
    service = fixture.service.asset.service;
    toasts = fixture.service.toast;
  });

  tearDown(() async {
    verifyNever(() => service.deleteWithResults(any()));
    verifyNever(() => service.cancelDeletionBatch(any()));
    verifyNever(() => fixture.service.cleanup.service.deleteLocalAssetsDetailed(any()));
    await fixture.dispose();
  });

  RemoteAsset asset(String id) => RemoteAssetFactory.create(
    id: id,
    ownerId: fixture.currentUser.id,
    localId: 'device-$id',
    deletedAt: DateTime.utc(2026, 11, 2),
  );

  List<PermanentDeletionResult> accepted(Iterable<String> ids, {String state = 'pending'}) => [
    for (final id in ids) PermanentDeletionResult(id: id, state: state, serverAccepted: true),
  ];

  Future<ProviderContainer> mount(
    WidgetTester tester,
    Set<BaseAsset> selection, {
    ActionSource source = ActionSource.timeline,
    bool menu = false,
  }) async {
    await tester.pumpTestWidget(
      fixture,
      Column(
        children: [
          if (menu)
            ImmichMenu(
              children: [ActionMenuItem(action: DeleteAction(source: source))],
              builder: (_, controller, _) =>
                  TextButton(onPressed: controller.open, child: const Text('Open selected actions')),
            )
          else
            ActionIconButton(action: DeleteAction(source: source)),
          ActionButton(action: RestoreAction(source: source)),
        ],
      ),
      overrides: [
        ...fixture.selected(selection),
        toastServiceProvider.overrideWithValue(toasts),
        if (source == .viewer) assetsActionProvider(source).overrideWithValue(AssetFilter(selection)),
      ],
    );
    return ProviderScope.containerOf(
      tester.element(find.byType(menu ? MenuAnchor : ActionIconButton).first),
      listen: false,
    );
  }

  Future<void> request(WidgetTester tester, {bool menu = false}) async {
    if (menu) {
      await tester.tap(find.text('Open selected actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ImmichMenuItem));
    } else {
      await tester.tap(find.byType(ImmichIconButton));
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ConfirmDialog), findsOneWidget);
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(ConfirmDialog),
        matching: find.widgetWithText(TextButton, StaticTranslations.instance.delete_permanently),
      ),
    );
    // An unresolved acceptance keeps the real button's spinner alive; do not
    // pumpAndSettle until the synthetic HTTP/service response has been supplied.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  String admissionMessage(int count) => StaticTranslations.instance.permanent_deletion_accepted(count: count);

  void noSuccess() => verifyNever(() => toasts.success(any(), toast: any(named: 'toast')));

  for (final count in [1, 3, 500]) {
    testWidgets('$count selected photos succeed on accepted pending receipts without physical polling or Undo', (
      tester,
    ) async {
      final selected = {for (var index = 0; index < count; index++) asset('selected-$index')};
      final ids = selected.map((item) => item.id).toList();
      final response = Completer<List<PermanentDeletionResult>>();
      when(() => service.acceptPermanentDeletion(ids)).thenAnswer((_) => response.future);
      final container = await mount(tester, selected);
      await request(tester);
      verifyNever(() => service.acceptPermanentDeletion(any()));
      await confirm(tester);

      verify(() => service.acceptPermanentDeletion(ids)).called(1);
      expect(container.read(multiSelectProvider).selectedAssets, selected);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(BatchDeletionDialog), findsNothing);
      noSuccess();

      response.complete(accepted(ids));
      await tester.pumpAndSettle();
      verify(() => toasts.success(admissionMessage(count), toast: null)).called(1);
      verifyNever(() => toasts.error(any(), toast: any(named: 'toast')));
      expect(container.read(multiSelectProvider).selectedAssets, isEmpty);
      expect(find.byType(ImmichTextButton), findsNothing, reason: 'there is no accepted photo left to Restore');
      expect(find.text('Undo'), findsNothing);
      expect(find.byType(BatchDeletionDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('accepted failed physical work is still irreversible admission and does not wait for retries', (
    tester,
  ) async {
    final selected = asset('physical-retry');
    when(() => service.acceptPermanentDeletion([selected.id])).thenAnswer(
      (_) async => [
        PermanentDeletionResult(id: selected.id, state: 'failed', serverAccepted: true, code: 'RETRYABLE_FILE_IO'),
      ],
    );
    final container = await mount(tester, {selected});
    await request(tester);
    await confirm(tester);
    await tester.pumpAndSettle();
    verify(() => toasts.success(admissionMessage(1), toast: null)).called(1);
    expect(container.read(multiSelectProvider).selectedAssets, isEmpty);
    verifyNever(() => service.restoreTrash(any()));
  });

  testWidgets('partial admission deselects only accepted photos and retains rejected photos for review', (
    tester,
  ) async {
    final first = asset('accepted');
    final second = asset('rejected');
    when(() => service.acceptPermanentDeletion([first.id, second.id])).thenAnswer(
      (_) async => [
        ...accepted([first.id]),
        PermanentDeletionResult(id: second.id, state: 'blocked', code: 'REQUEST_REJECTED'),
      ],
    );
    final container = await mount(tester, {first, second});
    await request(tester);
    await confirm(tester);
    await tester.pumpAndSettle();
    expect(container.read(multiSelectProvider).selectedAssets, {second});
    noSuccess();
    verify(() => toasts.error(any(), toast: null)).called(1);
    // Restore may operate only on the rejected selection, never the accepted ID.
    await tester.tap(find.byType(ImmichTextButton));
    await tester.pumpAndSettle();
    verify(() => service.restoreTrash([second.id])).called(1);
    verifyNever(() => service.restoreTrash([first.id]));
  });

  for (final (state, code) in [
    ('blocked', 'REQUEST_REJECTED'),
    ('uncertain', 'REQUEST_OUTCOME_UNKNOWN'),
    ('pending', 'DELETION_BATCH_QUEUED'),
  ]) {
    testWidgets('$state without explicit acceptance preserves selection and never shows green success', (tester) async {
      final selected = asset('unaccepted');
      when(
        () => service.acceptPermanentDeletion([selected.id]),
      ).thenAnswer((_) async => [PermanentDeletionResult(id: selected.id, state: state, code: code)]);
      final container = await mount(tester, {selected});
      await request(tester);
      await confirm(tester);
      await tester.pumpAndSettle();
      expect(container.read(multiSelectProvider).selectedAssets, {selected});
      noSuccess();
      verify(() => toasts.error(any(), toast: null)).called(1);
      expect(find.byType(BatchDeletionDialog), findsNothing);
    });
  }

  testWidgets('an unselected photo added while acceptance runs is not cleared by a successful old snapshot', (
    tester,
  ) async {
    final selected = asset('captured');
    final later = asset('later-selection');
    final response = Completer<List<PermanentDeletionResult>>();
    when(() => service.acceptPermanentDeletion([selected.id])).thenAnswer((_) => response.future);
    final container = await mount(tester, {selected});
    await request(tester);
    await confirm(tester);
    container.read(multiSelectProvider.notifier).selectAsset(later);
    await tester.pump();
    response.complete(accepted([selected.id]));
    await tester.pumpAndSettle();
    expect(container.read(multiSelectProvider).selectedAssets, {later});
    verify(() => service.acceptPermanentDeletion([selected.id])).called(1);
    verify(() => toasts.success(admissionMessage(1), toast: null)).called(1);
  });

  testWidgets('retained callbacks cannot open duplicate confirmations or submit while admission is pending', (
    tester,
  ) async {
    final selected = asset('repeat');
    final response = Completer<List<PermanentDeletionResult>>();
    when(() => service.acceptPermanentDeletion([selected.id])).thenAnswer((_) => response.future);
    await mount(tester, {selected});
    final callback = tester.widget<ImmichIconButton>(find.byType(ImmichIconButton)).onPressed;
    final first = Future<void>.sync(callback);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await Future<void>.sync(callback);
    await tester.pump();
    expect(find.byType(ConfirmDialog), findsOneWidget);
    await confirm(tester);
    await Future<void>.sync(callback);
    await tester.pump();
    verify(() => service.acceptPermanentDeletion([selected.id])).called(1);
    expect(find.byType(ConfirmDialog), findsNothing);
    noSuccess();
    response.complete(accepted([selected.id]));
    await tester.pumpAndSettle();
    await first;
    verifyNever(() => service.acceptPermanentDeletion(any()));
  });

  testWidgets('overflow-menu permanent deletion uses the same admitted snapshot', (tester) async {
    final selected = asset('menu');
    when(() => service.acceptPermanentDeletion([selected.id])).thenAnswer((_) async => accepted([selected.id]));
    await mount(tester, {selected}, menu: true);
    await request(tester, menu: true);
    await confirm(tester);
    await tester.pumpAndSettle();
    verify(() => service.acceptPermanentDeletion([selected.id])).called(1);
    verify(() => toasts.success(admissionMessage(1), toast: null)).called(1);
    expect(find.byType(BatchDeletionDialog), findsNothing);
  });

  testWidgets('viewer deletion admits the single selected frame without device cleanup or stack expansion', (
    tester,
  ) async {
    final selected = asset('viewer');
    when(() => service.acceptPermanentDeletion([selected.id])).thenAnswer((_) async => accepted([selected.id]));
    await mount(tester, {selected}, source: ActionSource.viewer);
    await request(tester);
    await confirm(tester);
    await tester.pumpAndSettle();
    verify(() => service.acceptPermanentDeletion([selected.id])).called(1);
    verifyNever(() => service.resolveStackTrashIds(any(), any()));
    verify(() => toasts.success(admissionMessage(1), toast: null)).called(1);
  });

  testWidgets('cancelling confirmation leaves the original selection without contacting admission', (tester) async {
    final selected = asset('cancelled');
    final container = await mount(tester, {selected});
    await request(tester);
    await tester.tap(find.widgetWithText(TextButton, StaticTranslations.instance.cancel));
    await tester.pumpAndSettle();
    verifyNever(() => service.acceptPermanentDeletion(any()));
    expect(container.read(multiSelectProvider).selectedAssets, {selected});
    noSuccess();
  });

  testWidgets('leaving the screen does not cancel an accepted server operation or touch a disposed widget', (
    tester,
  ) async {
    final selected = asset('leave');
    final response = Completer<List<PermanentDeletionResult>>();
    when(() => service.acceptPermanentDeletion([selected.id])).thenAnswer((_) => response.future);
    await mount(tester, {selected});
    await request(tester);
    await confirm(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    response.complete(accepted([selected.id]));
    await tester.pumpAndSettle();
    verify(() => service.acceptPermanentDeletion([selected.id])).called(1);
    noSuccess();
    expect(tester.takeException(), isNull);
  });
}
