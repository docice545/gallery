import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../service.mocks.dart';
import '../../factories/local_asset_factory.dart';
import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

void main() {
  late PresentationContext context;
  late MockAssetService assetService;
  late MockCleanupService cleanupService;

  setUp(() async {
    context = await PresentationContext.create();
    assetService = context.service.asset.service;
    cleanupService = context.service.cleanup.service;
    when(() => assetService.getDeletionLocalIds(any())).thenAnswer((_) async => []);
    when(() => assetService.deleteWithResults(any())).thenAnswer(
      (call) async => (call.positionalArguments.first as List<String>)
          .map((id) => PermanentDeletionResult(id: id, state: 'complete'))
          .toList(),
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await StoreService.I.put(StoreKey.manageLocalMediaAndroid, false);
    await context.dispose();
  });

  RemoteAsset owned({AssetVisibility visibility = .timeline, DateTime? deletedAt, String? localId}) =>
      RemoteAssetFactory.create(
        ownerId: context.currentUser.id,
        visibility: visibility,
        deletedAt: deletedAt,
        localId: localId,
      );

  Future<void> pumpDelete(
    WidgetTester tester,
    Set<BaseAsset> selection, {
    bool trashEnabled = true,
    bool everywhere = false,
    bool device = false,
  }) async {
    if (!trashEnabled) {
      when(
        () => context.service.serverInfo.getServerFeatures(),
      ).thenAnswer((_) async => const .new(trash: false, map: true, oauthEnabled: false, passwordLogin: true));
    }

    await tester.pumpTestWidget(
      context,
      ActionIconButton(
        action: device
            ? const CleanupLocalAction(source: .timeline)
            : everywhere
            ? const DeleteEverywhereAction(source: .timeline)
            : const DeleteAction(source: .timeline),
      ),
      overrides: context.selected(selection),
    );

    if (!trashEnabled) {
      final scope = ProviderScope.containerOf(tester.element(find.byType(ActionIconButton)), listen: false);
      await scope.read(serverInfoProvider.notifier).getServerFeatures();
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byType(ImmichIconButton));
    await tester.pump();
  }

  Future<void> respondToDialog(WidgetTester tester, {required bool confirm}) async {
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ConfirmDialog), findsOneWidget);
    await tester.tap(find.byType(TextButton).at(confirm ? 1 : 0)); // [cancel, ok]
    await tester.pumpAndSettle();
  }

  group('DeleteAction', () {
    group('trash', () {
      testWidgets('trashes a remote-only owned asset', (tester) async {
        final asset = owned();

        await pumpDelete(tester, {asset});
        await tester.pumpAndSettle();

        verify(() => assetService.trash([asset.id])).called(1);
        verifyNever(() => assetService.deleteWithResults(any()));
        verifyNever(() => cleanupService.deleteLocalAssetsDetailed(any()));
      });

      testWidgets('ignores assets owned by someone else', (tester) async {
        final mine = owned();
        final theirs = RemoteAssetFactory.create();

        await pumpDelete(tester, {mine, theirs});
        await tester.pumpAndSettle();

        verify(() => assetService.trash([mine.id])).called(1);
      });

      testWidgets('Gallery-only Trash leaves a backed-up device copy intact', (tester) async {
        final asset = owned(localId: 'local');

        await pumpDelete(tester, {asset});
        await tester.pumpAndSettle();

        verifyNever(() => cleanupService.deleteLocalAssetsDetailed(any()));
        verify(() => assetService.trash([asset.id])).called(1);
      });

      testWidgets('Gallery-only mixed selection trashes only owned server assets', (tester) async {
        final backedUp = owned(localId: 'backed-up-local');
        final localOnly = LocalAssetFactory.create(id: 'local-only');

        await pumpDelete(tester, {backedUp, localOnly});
        await tester.pumpAndSettle();

        verify(() => assetService.trash([backedUp.id])).called(1);
        verifyNever(() => cleanupService.deleteLocalAssetsDetailed(any()));
      });

      testWidgets('Gallery-only deletion of a backed-up local-album representation preserves the device copy', (
        tester,
      ) async {
        final local = LocalAssetFactory.create(id: 'local-album-copy', remoteId: 'own-cloud-id');
        await pumpDelete(tester, {local});
        await tester.pumpAndSettle();
        verify(() => assetService.trash(['own-cloud-id'])).called(1);
        verifyNever(() => cleanupService.deleteLocalAssetsDetailed(any()));
      });

      testWidgets('offers an undo that restores the trashed assets', (tester) async {
        final asset = owned();

        await pumpDelete(tester, {asset});
        await tester.pumpAndSettle();
        await tester.tap(find.text('Undo'));
        await tester.pump();

        verify(() => assetService.restoreTrash([asset.id])).called(1);
      });
    });

    group('DeleteEverywhereAction', () {
      testWidgets('waits for cloud Trash before deleting device copies', (tester) async {
        final asset = owned(localId: 'phone-copy');
        final accepted = Completer<void>();
        when(() => assetService.trash(any())).thenAnswer((_) => accepted.future);
        await pumpDelete(tester, {asset}, everywhere: true);
        verifyNever(() => cleanupService.deleteLocalAssetsDetailed(any()));
        accepted.complete();
        await tester.pumpAndSettle();
        verify(() => cleanupService.deleteLocalAssetsDetailed(['phone-copy'])).called(1);
        expect(find.text('Undo'), findsNothing);
      });

      testWidgets('cloud rejection never deletes the only local copy', (tester) async {
        final asset = owned(localId: 'phone-copy');
        when(() => assetService.trash(any())).thenThrow(StateError('fixture offline'));
        await pumpDelete(tester, {asset}, everywhere: true);
        await tester.pumpAndSettle();
        verifyNever(() => cleanupService.deleteLocalAssetsDetailed(any()));
        verifyNever(() => assetService.deleteWithResults(any()));
      });

      testWidgets('bulk local denial reports remaining copies and preserves selection', (tester) async {
        final photo = owned(localId: 'local-photo');
        final video = RemoteAssetFactory.create(ownerId: context.currentUser.id, localId: 'local-video', type: .video);
        when(() => cleanupService.deleteLocalAssetsDetailed(any())).thenAnswer(
          (_) async => const LocalDeletionResult(deletedIds: ['local-photo'], remainingIds: ['local-video']),
        );
        await pumpDelete(tester, {photo, video}, everywhere: true);
        await tester.pumpAndSettle();
        verify(() => assetService.trash([photo.id, video.id])).called(1);
        expect(find.textContaining('1 removed, 1 remain'), findsOneWidget);
        final scope = ProviderScope.containerOf(tester.element(find.byType(ActionIconButton)), listen: false);
        expect(scope.read(multiSelectProvider).selectedAssets, {photo, video});
        expect(find.text('Undo'), findsNothing);
      });

      testWidgets('mixed everywhere operation includes local-only copies after cloud acceptance', (tester) async {
        final backedUp = owned(localId: 'backed-up');
        final localOnly = LocalAssetFactory.create(id: 'local-only');
        await pumpDelete(tester, {backedUp, localOnly}, everywhere: true);
        await tester.pumpAndSettle();
        verify(() => assetService.trash([backedUp.id])).called(1);
        verify(() => cleanupService.deleteLocalAssetsDetailed(['backed-up', 'local-only'])).called(1);
      });

      testWidgets('everywhere deletion supports backed-up local-album representations', (tester) async {
        final local = LocalAssetFactory.create(id: 'local-album-copy', remoteId: 'own-cloud-id');
        await pumpDelete(tester, {local}, everywhere: true);
        await tester.pumpAndSettle();
        verify(() => assetService.trash(['own-cloud-id'])).called(1);
        verify(() => cleanupService.deleteLocalAssetsDetailed(['local-album-copy'])).called(1);
      });

      testWidgets('cannot delete a different owner device copy', (tester) async {
        final own = owned(localId: 'mine');
        final other = RemoteAssetFactory.create(localId: 'other-phone');
        await pumpDelete(tester, {own, other}, everywhere: true);
        await tester.pumpAndSettle();
        verify(() => assetService.trash([own.id])).called(1);
        verify(() => cleanupService.deleteLocalAssetsDetailed(['mine'])).called(1);
      });
    });

    group('permanent', () {
      testWidgets('trashes active assets even when the old trash feature flag is disabled', (tester) async {
        final asset = owned();
        await pumpDelete(tester, {asset}, trashEnabled: false);
        await tester.pumpAndSettle();
        verify(() => assetService.trash([asset.id])).called(1);
        verifyNever(() => assetService.deleteWithResults(any()));
      });

      testWidgets('offers no undo for a permanent delete', (tester) async {
        await pumpDelete(tester, {owned(deletedAt: DateTime(2024))}, trashEnabled: false);
        await respondToDialog(tester, confirm: true);
        await tester.pumpAndSettle();

        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.text('Undo'), findsNothing);
      });

      testWidgets('permanently deletes a merged asset and removes its device copy', (tester) async {
        final asset = owned(deletedAt: DateTime(2024), localId: 'local');

        await pumpDelete(tester, {asset}, trashEnabled: false);
        await respondToDialog(tester, confirm: true);

        verify(() => assetService.deleteWithResults([asset.id])).called(1);
        verify(() => cleanupService.deleteLocalAssetsDetailed(['local'], trash: false)).called(1);
      });

      testWidgets('permanently deletes already trashed assets even with trash enabled', (tester) async {
        final asset = owned(deletedAt: DateTime(2024));

        await pumpDelete(tester, {asset});
        await respondToDialog(tester, confirm: true);

        verify(() => assetService.deleteWithResults([asset.id])).called(1);
        verifyNever(() => assetService.trash(any()));
      });

      testWidgets('permanently deletes locked folder assets even with trash enabled', (tester) async {
        final asset = owned(deletedAt: DateTime(2024), localId: 'local');

        await pumpDelete(tester, {asset});
        await respondToDialog(tester, confirm: true);

        verify(() => assetService.deleteWithResults([asset.id])).called(1);
        verify(() => cleanupService.deleteLocalAssetsDetailed(['local'], trash: false)).called(1);
      });

      testWidgets('does nothing when the confirmation is cancelled', (tester) async {
        final asset = owned(deletedAt: DateTime(2024), localId: 'local');

        await pumpDelete(tester, {asset});
        await respondToDialog(tester, confirm: false);

        verifyNever(() => assetService.deleteWithResults(any()));
        verifyNever(() => cleanupService.deleteLocalAssetsDetailed(any()));
      });
    });

    group('local only', () {
      testWidgets('removes the device copy with no remote call', (tester) async {
        final asset = LocalAssetFactory.create();

        await pumpDelete(tester, {asset}, device: true);
        await tester.pumpAndSettle();

        verify(() => cleanupService.deleteLocalAssetsDetailed([asset.id])).called(1);
        verifyNever(() => assetService.trash(any()));
        verifyNever(() => assetService.deleteWithResults(any()));
      });

      testWidgets('Gallery-only action is hidden for a local-only asset', (tester) async {
        await tester.pumpTestWidget(
          context,
          const ActionButton(action: DeleteAction(source: .timeline)),
          overrides: context.selected({LocalAssetFactory.create()}),
        );

        expect(find.byType(ImmichTextButton), findsNothing);
        expect(find.text(StaticTranslations.instance.delete_from_gallery), findsNothing);
      });
    });

    group('prompt handling', () {
      testWidgets('permanent delete shows a single app dialog', (tester) async {
        final asset = owned(deletedAt: DateTime(2024), localId: 'local');

        await pumpDelete(tester, {asset}, trashEnabled: false);
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text(StaticTranslations.instance.delete_dialog_title), findsOneWidget);
        await tester.tap(find.byType(TextButton).at(1));
        await tester.pumpAndSettle();

        expect(find.text(StaticTranslations.instance.move_to_device_trash), findsNothing);
        verify(() => assetService.deleteWithResults([asset.id])).called(1);
        verify(() => cleanupService.deleteLocalAssetsDetailed(['local'], trash: false)).called(1);
      });

      testWidgets('local only delete on Android with MANAGE_MEDIA shows the prompt', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await StoreService.I.put(StoreKey.manageLocalMediaAndroid, true);
        final asset = LocalAssetFactory.create();

        await pumpDelete(tester, {asset}, device: true);
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text(StaticTranslations.instance.move_to_device_trash), findsOneWidget);
        await tester.tap(find.byType(TextButton).at(1)); // confirm
        await tester.pumpAndSettle();

        verify(() => cleanupService.deleteLocalAssetsDetailed([asset.id])).called(1);
        // Has to be cleared inside the body; the framework asserts on it before tearDown runs.
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('local only delete on Android with MANAGE_MEDIA deletes nothing when cancelled', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await StoreService.I.put(StoreKey.manageLocalMediaAndroid, true);
        final asset = LocalAssetFactory.create();

        await pumpDelete(tester, {asset}, device: true);
        await respondToDialog(tester, confirm: false);

        verifyNever(() => cleanupService.deleteLocalAssetsDetailed(any()));
        debugDefaultTargetPlatformOverride = null;
      });
    });

    testWidgets('Russian narrow-screen menu distinguishes all three deletion modes', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpTestWidget(
        context,
        const Column(
          children: [
            ActionButton(action: DeleteAction(source: .timeline)),
            ActionButton(action: CleanupLocalAction(source: .timeline)),
            ActionButton(action: DeleteEverywhereAction(source: .timeline)),
          ],
        ),
        overrides: context.selected({owned(localId: 'phone')}),
      );
      await EasyLocalization.of(tester.element(find.byType(Column).first))!.setLocale(const Locale('ru'));
      await tester.pumpAndSettle();
      expect(find.text('Удалить из «Фото»'), findsOneWidget);
      expect(find.text('Удалить с устройства'), findsOneWidget);
      expect(find.text('Удалить везде'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('is hidden when nothing can be deleted', (tester) async {
      await tester.pumpTestWidget(
        context,
        const ActionIconButton(action: DeleteAction(source: .timeline)),
        overrides: context.selected({RemoteAssetFactory.create()}),
      );

      expect(find.byType(ImmichIconButton), findsNothing);
    });
  });

  group('CleanupLocalAction', () {
    testWidgets('device-only deletion handles both backed-up and local-only copies', (tester) async {
      final backedUp = LocalAssetFactory.create(remoteId: 'remote');
      final localOnly = LocalAssetFactory.create();

      await tester.pumpTestAction(
        context,
        const CleanupLocalAction(source: .timeline),
        overrides: context.selected({backedUp, localOnly}),
      );
      await tester.pumpAndSettle();

      verify(() => cleanupService.deleteLocalAssetsDetailed([backedUp.id, localOnly.id])).called(1);
      verifyNever(() => assetService.trash(any()));
      verifyNever(() => assetService.deleteWithResults(any()));
    });

    testWidgets('device-only permission denial never changes the cloud or clears selection', (tester) async {
      final asset = owned(localId: 'kept-phone');
      when(
        () => cleanupService.deleteLocalAssetsDetailed(any()),
      ).thenAnswer((_) async => const LocalDeletionResult(deletedIds: [], remainingIds: ['kept-phone']));
      await pumpDelete(tester, {asset}, device: true);
      await tester.pumpAndSettle();
      verifyNever(() => assetService.trash(any()));
      verifyNever(() => assetService.deleteWithResults(any()));
      expect(find.textContaining('0 removed, 1 remain'), findsOneWidget);
      final scope = ProviderScope.containerOf(tester.element(find.byType(ActionIconButton)), listen: false);
      expect(scope.read(multiSelectProvider).selectedAssets, {asset});
    });

    testWidgets('local-only assets have a clearly labelled device action', (tester) async {
      await tester.pumpTestWidget(
        context,
        const ActionButton(action: CleanupLocalAction(source: .timeline)),
        overrides: context.selected({LocalAssetFactory.create()}),
      );

      expect(find.text(StaticTranslations.instance.delete_from_device), findsOneWidget);
    });
  });
}
