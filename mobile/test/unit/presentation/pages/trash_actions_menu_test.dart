import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/trash.page.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:mocktail/mocktail.dart';

import '../../factories/user_factory.dart';
import '../presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
    when(() => context.service.asset.service.getTrashIds(any())).thenAnswer((_) async => ['photo', 'video']);
    when(() => context.service.asset.service.deleteWithResults(any())).thenAnswer(
      (call) async => (call.positionalArguments.first as List<String>)
          .map((id) => PermanentDeletionResult(id: id, state: 'complete'))
          .toList(),
    );
    when(() => context.service.asset.service.getDeletionLocalIds(any())).thenAnswer((_) async => ['phone-photo']);
    when(
      () => context.service.asset.service.getPendingDeviceDeletionAssetIds(any()),
    ).thenAnswer((_) async => ['completed-server-receipt']);
    when(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: false)).thenAnswer(
      (call) async => LocalDeletionResult(deletedIds: call.positionalArguments.first as List<String>, remainingIds: []),
    );
  });

  tearDown(() async => context.dispose());

  Future<void> openEmptyTrash(WidgetTester tester) async {
    await tester.pumpTestWidget(context, const TrashActionsMenu());
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text(StaticTranslations.instance.empty_trash));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmDialog), findsOneWidget);
  }

  Future<void> openDeviceRetry(WidgetTester tester, {bool pump = true}) async {
    if (pump) {
      await tester.pumpTestWidget(context, const TrashActionsMenu());
    }
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text(StaticTranslations.instance.device_deletion_retry));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmDialog), findsOneWidget);
    expect(find.text(StaticTranslations.instance.device_deletion_retry_confirmation), findsOneWidget);
  }

  Future<void> confirm(WidgetTester tester, {bool accepted = true}) async {
    await tester.tap(find.byType(TextButton).at(accepted ? 1 : 0));
    await tester.pumpAndSettle();
  }

  Future<void> dismissToast(WidgetTester tester) async {
    // Exercise the real overlay and let its bounded duration finish rather
    // than leaving a plugin timer behind at widget disposal.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  testWidgets('cancelling Empty Trash never reads or changes the server or device selection', (tester) async {
    await openEmptyTrash(tester);
    await confirm(tester, accepted: false);
    verifyNever(() => context.service.asset.service.getTrashIds(any()));
    verifyNever(() => context.service.asset.service.deleteWithResults(any()));
    verifyNever(() => context.service.asset.service.getDeletionLocalIds(any()));
    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: false));
  });

  testWidgets('captures only the authenticated owner Trash and permanently cleans its completed copies', (
    tester,
  ) async {
    await openEmptyTrash(tester);
    await confirm(tester);
    verify(() => context.service.asset.service.getTrashIds(context.currentUser.id)).called(1);
    verify(() => context.service.asset.service.deleteWithResults(['photo', 'video'])).called(1);
    verify(() => context.service.asset.service.getDeletionLocalIds(['photo', 'video'])).called(1);
    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed(['phone-photo'], trash: false)).called(1);
    expect(find.textContaining('2 permanently deleted, 0 incomplete'), findsOneWidget);
    expect(find.textContaining('1 removed, 0 remain'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    await dismissToast(tester);
  });

  testWidgets('waits for the permanent server acknowledgement before requesting device deletion', (tester) async {
    final response = Completer<List<PermanentDeletionResult>>();
    when(() => context.service.asset.service.deleteWithResults(any())).thenAnswer((_) => response.future);
    await openEmptyTrash(tester);
    await tester.tap(find.byType(TextButton).at(1));
    await tester.pumpAndSettle();
    verifyNever(() => context.service.asset.service.getDeletionLocalIds(any()));
    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: false));
    response.complete([const PermanentDeletionResult(id: 'photo', state: 'complete')]);
    await tester.pumpAndSettle();
    verify(() => context.service.asset.service.getDeletionLocalIds(['photo'])).called(1);
    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed(['phone-photo'], trash: false)).called(1);
    await dismissToast(tester);
  });

  testWidgets('pending failed and blocked server results never authorize device cleanup', (tester) async {
    when(
      () => context.service.asset.service.getTrashIds(any()),
    ).thenAnswer((_) async => ['complete', 'pending', 'failed', 'blocked']);
    when(() => context.service.asset.service.deleteWithResults(any())).thenAnswer(
      (_) async => [
        const PermanentDeletionResult(id: 'complete', state: 'complete'),
        const PermanentDeletionResult(id: 'pending', state: 'pending'),
        const PermanentDeletionResult(id: 'failed', state: 'failed', code: 'ORIGINAL_DELETE_FAILED'),
        const PermanentDeletionResult(id: 'blocked', state: 'blocked', code: 'LIBRARY_DELETION_NOT_AUTHORIZED'),
      ],
    );
    await openEmptyTrash(tester);
    await confirm(tester);
    verify(() => context.service.asset.service.getDeletionLocalIds(['complete'])).called(1);
    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed(['phone-photo'], trash: false)).called(1);
    expect(find.textContaining('1 permanently deleted, 3 incomplete'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    await dismissToast(tester);
  });

  testWidgets('mixed-scope authorization failure preserves all device copies and reports no server success', (
    tester,
  ) async {
    when(() => context.service.asset.service.deleteWithResults(any())).thenAnswer(
      (_) async => [
        const PermanentDeletionResult(id: 'photo', state: 'blocked', code: 'DELETION_BATCH_NOT_AUTHORIZED'),
        const PermanentDeletionResult(id: 'video', state: 'blocked', code: 'LIBRARY_DELETION_NOT_AUTHORIZED'),
      ],
    );
    when(() => context.service.asset.service.getDeletionLocalIds([])).thenAnswer((_) async => []);
    await openEmptyTrash(tester);
    await confirm(tester);
    verify(() => context.service.asset.service.getDeletionLocalIds([])).called(1);
    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed([], trash: false)).called(1);
    expect(find.textContaining('0 permanently deleted, 2 incomplete'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    await dismissToast(tester);
  });

  testWidgets('OS partial permission denial reports remaining copies rather than total deletion', (tester) async {
    when(
      () => context.service.asset.service.getDeletionLocalIds(any()),
    ).thenAnswer((_) async => ['phone-photo', 'phone-video']);
    when(
      () => context.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: false),
    ).thenAnswer((_) async => const LocalDeletionResult(deletedIds: ['phone-photo'], remainingIds: ['phone-video']));
    await openEmptyTrash(tester);
    await confirm(tester);
    expect(find.textContaining('2 permanently deleted, 0 incomplete'), findsOneWidget);
    expect(find.textContaining('1 removed, 1 remain'), findsOneWidget);
    expect(find.textContaining('phone-video'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    await dismissToast(tester);
  });

  testWidgets('an empty captured selection cannot delete other or newly arriving server and device assets', (
    tester,
  ) async {
    when(() => context.service.asset.service.getTrashIds(any())).thenAnswer((_) async => []);
    when(() => context.service.asset.service.getDeletionLocalIds([])).thenAnswer((_) async => []);
    await openEmptyTrash(tester);
    await confirm(tester);
    verify(() => context.service.asset.service.deleteWithResults([])).called(1);
    verify(() => context.service.asset.service.getDeletionLocalIds([])).called(1);
    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed([], trash: false)).called(1);
    expect(find.textContaining('0 permanently deleted, 0 incomplete'), findsOneWidget);
    expect(find.textContaining('0 removed, 0 remain'), findsOneWidget);
    await dismissToast(tester);
  });

  for (final stage in ['server acknowledgement', 'local identity lookup']) {
    testWidgets('account switch during Empty Trash $stage prevents device deletion', (tester) async {
      final userChanges = StreamController<UserDto?>();
      addTearDown(userChanges.close);
      when(() => context.service.user.service.watchMyUser()).thenAnswer((_) => userChanges.stream);
      final serverResponse = Completer<List<PermanentDeletionResult>>();
      final localResponse = Completer<List<String>>();
      if (stage == 'server acknowledgement') {
        when(() => context.service.asset.service.deleteWithResults(any())).thenAnswer((_) => serverResponse.future);
      } else {
        when(() => context.service.asset.service.getDeletionLocalIds(any())).thenAnswer((_) => localResponse.future);
      }
      await openEmptyTrash(tester);
      await tester.tap(find.byType(TextButton).at(1));
      await tester.pumpAndSettle();
      userChanges.add(UserFactory.createDto(id: 'other-owner'));
      await tester.pump();
      if (stage == 'server acknowledgement') {
        serverResponse.complete([const PermanentDeletionResult(id: 'photo', state: 'complete')]);
      } else {
        localResponse.complete(['phone-photo']);
      }
      await tester.pumpAndSettle();
      verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: false));
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    });
  }

  testWidgets('cancelling device retry performs no receipt lookup or device operation', (tester) async {
    await openDeviceRetry(tester);
    await confirm(tester, accepted: false);
    verifyNever(() => context.service.asset.service.getPendingDeviceDeletionAssetIds(any()));
    verifyNever(() => context.service.asset.service.getDeletionLocalIds(any()));
    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: false));
    verifyNever(() => context.service.asset.service.deleteWithResults(any()));
    verifyNever(() => context.service.asset.service.getTrashIds(any()));
  });

  testWidgets('device retry selects only the authenticated owner completed receipts without server changes', (
    tester,
  ) async {
    await openDeviceRetry(tester);
    await confirm(tester);
    verify(() => context.service.asset.service.getPendingDeviceDeletionAssetIds(context.currentUser.id)).called(1);
    verify(() => context.service.asset.service.getDeletionLocalIds(['completed-server-receipt'])).called(1);
    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed(['phone-photo'], trash: false)).called(1);
    verifyNever(() => context.service.asset.service.deleteWithResults(any()));
    verifyNever(() => context.service.asset.service.getTrashIds(any()));
    verifyNever(() => context.service.asset.service.trash(any()));
    verifyNever(() => context.service.asset.service.restoreTrash(any()));
    expect(find.textContaining('1 removed, 0 remain'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    await dismissToast(tester);
  });

  testWidgets('device retry with no eligible receipts never guesses local identities or changes the cloud', (
    tester,
  ) async {
    when(() => context.service.asset.service.getPendingDeviceDeletionAssetIds(any())).thenAnswer((_) async => []);
    await openDeviceRetry(tester);
    await confirm(tester);
    verifyNever(() => context.service.asset.service.getDeletionLocalIds(any()));
    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: false));
    verifyNever(() => context.service.asset.service.deleteWithResults(any()));
    expect(find.text(StaticTranslations.instance.device_deletion_retry_none), findsOneWidget);
    await dismissToast(tester);
  });

  testWidgets('device retry refuses receipts with no currently verified device identities', (tester) async {
    when(() => context.service.asset.service.getDeletionLocalIds(any())).thenAnswer((_) async => []);
    await openDeviceRetry(tester);
    await confirm(tester);
    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: false));
    verifyNever(() => context.service.asset.service.deleteWithResults(any()));
    expect(find.text(StaticTranslations.instance.device_deletion_retry_none), findsOneWidget);
    await dismissToast(tester);
  });

  testWidgets('denied device retry remains available and a second explicitly confirmed attempt succeeds', (
    tester,
  ) async {
    var attempts = 0;
    when(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: false)).thenAnswer(
      (_) async => ++attempts == 1
          ? const LocalDeletionResult(deletedIds: [], remainingIds: ['phone-photo'])
          : const LocalDeletionResult(deletedIds: ['phone-photo'], remainingIds: []),
    );
    await openDeviceRetry(tester);
    await confirm(tester);
    expect(find.textContaining('0 removed, 1 remain'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    await dismissToast(tester);
    await openDeviceRetry(tester, pump: false);
    await confirm(tester);
    expect(find.textContaining('1 removed, 0 remain'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed(['phone-photo'], trash: false)).called(2);
    verifyNever(() => context.service.asset.service.deleteWithResults(any()));
    verifyNever(() => context.service.asset.service.getTrashIds(any()));
    await dismissToast(tester);
  });

  testWidgets('account switch during device retry identity lookup prevents all OS operations', (tester) async {
    final userChanges = StreamController<UserDto?>();
    addTearDown(userChanges.close);
    when(() => context.service.user.service.watchMyUser()).thenAnswer((_) => userChanges.stream);
    final localResponse = Completer<List<String>>();
    when(() => context.service.asset.service.getDeletionLocalIds(any())).thenAnswer((_) => localResponse.future);
    await openDeviceRetry(tester);
    await tester.tap(find.byType(TextButton).at(1));
    await tester.pumpAndSettle();
    userChanges.add(UserFactory.createDto(id: 'other-owner'));
    await tester.pump();
    localResponse.complete(['phone-photo']);
    await tester.pumpAndSettle();
    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: false));
    verifyNever(() => context.service.asset.service.deleteWithResults(any()));
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
  });

  testWidgets('Russian narrow-screen retry explains device-only deletion and required OS authorization', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpTestWidget(context, const TrashActionsMenu());
    await EasyLocalization.of(tester.element(find.byType(TrashActionsMenu)))!.setLocale(const Locale('ru'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Удалить оставшиеся копии на устройстве'), findsOneWidget);
    await tester.tap(find.text('Удалить оставшиеся копии на устройстве'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Данные сервера и NAS не изменятся'), findsOneWidget);
    expect(find.textContaining('Android или iOS могут запросить ваше разрешение'), findsOneWidget);
    await confirm(tester, accepted: false);
    verifyNever(() => context.service.asset.service.getPendingDeviceDeletionAssetIds(any()));
    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: false));
    expect(tester.takeException(), isNull);
  });
}
