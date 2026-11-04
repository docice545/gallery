import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/models/albums/album_search.model.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/local_album_bottom_sheet.widget.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/remote_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/shared_space.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../factories/local_asset_factory.dart';
import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

class _EmptyRemoteAlbums extends RemoteAlbumNotifier {
  @override
  RemoteAlbumState build() => const RemoteAlbumState(albums: []);

  @override
  Future<void> refresh() async {}

  @override
  List<RemoteAlbum> searchAlbums(
    List<RemoteAlbum> albums,
    String query,
    String? userId, [
    QuickFilterMode filterMode = QuickFilterMode.all,
  ]) => albums;
}

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    verifyNever(() => context.service.asset.service.trash(any()));
    verifyNever(() => context.service.asset.service.acceptPermanentDeletion(any()));
    verifyNever(() => context.service.asset.service.deleteWithResults(any()));
    await StoreService.I.put(StoreKey.serverEndpoint, PresentationContext.serverEndpoint);
    await context.dispose();
  });

  ProviderContainer scope(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(ActionButton).first), listen: false);

  Future<void> pumpAction(WidgetTester tester, Set<BaseAsset> selected, {int buttons = 1}) async {
    for (final asset in selected) {
      when(() => context.service.asset.service.getAsset(asset)).thenAnswer((_) async => asset);
    }
    await tester.pumpTestWidget(
      context,
      Column(
        children: List.generate(buttons, (_) => const ActionButton(action: CleanupLocalAction(source: .timeline))),
      ),
      overrides: context.selected(selected),
    );
  }

  testWidgets('the actual local album sheet exposes device removal for local-only selection', (tester) async {
    final local = LocalAssetFactory.create();
    when(() => context.service.asset.service.getAsset(local)).thenAnswer((_) async => local);
    await tester.pumpTestWidget(
      context,
      const LocalAlbumBottomSheet(),
      overrides: [
        ...context.selected({local}),
        remoteAlbumProvider.overrideWith(_EmptyRemoteAlbums.new),
        appConfigProvider.overrideWithValue(const AppConfig()),
        sharedSpacesProvider.overrideWith((ref) async => const []),
      ],
    );

    await tester.tap(find.text('Delete from Device'));
    await tester.pumpAndSettle();

    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed([local.id])).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixed success deselects only device copies, retaining a remote-only selection', (tester) async {
    final local = LocalAssetFactory.create();
    final backedUp = LocalAssetFactory.create(remoteId: 'cloud-pair');
    final cloudOnly = RemoteAssetFactory.create(ownerId: context.currentUser.id);
    await pumpAction(tester, {local, backedUp, cloudOnly});
    final container = scope(tester);
    await tester.tap(find.text('Delete from Device'));
    await tester.pumpAndSettle();

    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed([local.id, backedUp.id])).called(1);
    expect(container.read(multiSelectProvider).selectedAssets, {cloudOnly});
  });

  testWidgets('partial result retains rejected copies and removes only acknowledged selection', (tester) async {
    final removed = LocalAssetFactory.create();
    final retained = RemoteAssetFactory.create(ownerId: context.currentUser.id, localId: 'device-retained');
    final cloudOnly = RemoteAssetFactory.create(ownerId: context.currentUser.id);
    when(
      () => context.service.cleanup.service.deleteLocalAssetsDetailed(any()),
    ).thenAnswer((_) async => LocalDeletionResult(deletedIds: [removed.id], remainingIds: [retained.localId!]));
    await pumpAction(tester, {removed, retained, cloudOnly});
    final container = scope(tester);
    await tester.tap(find.text('Delete from Device'));
    await tester.pumpAndSettle();

    expect(container.read(multiSelectProvider).selectedAssets, {retained, cloudOnly});
    expect(find.textContaining('1 removed, 1 remain'), findsOneWidget);
    expect(find.textContaining('Not removed:'), findsNothing);
  });

  testWidgets('system cancellation or permission refusal keeps the entire selection', (tester) async {
    final local = LocalAssetFactory.create();
    when(
      () => context.service.cleanup.service.deleteLocalAssetsDetailed(any()),
    ).thenAnswer((_) async => LocalDeletionResult(deletedIds: const [], remainingIds: [local.id]));
    await pumpAction(tester, {local});
    final container = scope(tester);
    await tester.tap(find.text('Delete from Device'));
    await tester.pumpAndSettle();

    expect(container.read(multiSelectProvider).selectedAssets, {local});
    expect(find.textContaining('0 removed, 1 remain'), findsOneWidget);
  });

  testWidgets('two button instances cannot start overlapping native cleanup operations', (tester) async {
    final local = LocalAssetFactory.create();
    final pending = Completer<LocalDeletionResult>();
    when(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any())).thenAnswer((_) => pending.future);
    await pumpAction(tester, {local}, buttons: 2);
    await tester.tap(find.text('Delete from Device').first);
    await tester.pump();
    await tester.tap(find.text('Delete from Device').last);
    await tester.pump();

    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed([local.id])).called(1);
    pending.complete(LocalDeletionResult(deletedIds: const [], remainingIds: [local.id]));
    await tester.pumpAndSettle();
  });

  testWidgets('a late result after server switching cannot clear the new selection or show success', (tester) async {
    final local = LocalAssetFactory.create();
    final pending = Completer<LocalDeletionResult>();
    when(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any())).thenAnswer((_) => pending.future);
    await pumpAction(tester, {local});
    final container = scope(tester);
    await tester.tap(find.text('Delete from Device'));
    await tester.pump();
    await StoreService.I.put(StoreKey.serverEndpoint, 'https://other.example.test/api');
    pending.complete(LocalDeletionResult(deletedIds: [local.id], remainingIds: const []));
    await tester.pumpAndSettle();

    expect(container.read(multiSelectProvider).selectedAssets, {local});
    expect(find.textContaining('1 removed, 0 remain'), findsNothing);
  });

  testWidgets('closing the action while native consent is pending does not access a disposed ref', (tester) async {
    final local = LocalAssetFactory.create();
    final pending = Completer<LocalDeletionResult>();
    when(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any())).thenAnswer((_) => pending.future);
    await pumpAction(tester, {local});
    await tester.tap(find.text('Delete from Device'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(LocalDeletionResult(deletedIds: [local.id], remainingIds: const []));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
