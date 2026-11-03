import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline_temporal_scope.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/pages/local_timeline.page.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:mocktail/mocktail.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../../widget_tester_extensions.dart';
import '../../factories/local_asset_factory.dart';
import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

class _MockTimelineFactory extends Mock implements TimelineFactory {}

void main() {
  const albumId = 'device-album';
  const label = 'Delete all album photos from device';
  late PresentationContext context;
  late MockLocalAlbumRepository repository;
  late MockDrift drift;
  late List<LocalAsset> assets;

  setUpAll(() {
    registerFallbackValue(const TimelineTemporalScope.none());
  });

  setUp(() async {
    context = await PresentationContext.create();
    repository = MockLocalAlbumRepository();
    drift = MockDrift();
    assets = [LocalAssetFactory.create(), LocalAssetFactory.create(remoteId: 'cloud-pair')];
    when(() => drift.localAlbumRepository).thenReturn(repository);
    when(() => repository.getAssets(albumId)).thenAnswer((_) async => assets);
  });

  tearDown(() async {
    verifyNever(() => repository.deleteAlbum(any()));
    verifyNever(() => repository.getAssetIds(any()));
    verifyNever(() => context.service.asset.service.trash(any()));
    verifyNever(() => context.service.asset.service.acceptPermanentDeletion(any()));
    verifyNever(() => context.service.asset.service.deleteWithResults(any()));
    await StoreService.I.put(StoreKey.serverEndpoint, PresentationContext.serverEndpoint);
    await context.dispose();
  });

  Future<void> pumpAction(WidgetTester tester, {Set<BaseAsset> selection = const {}, int buttons = 1}) async {
    await tester.pumpTestWidget(
      context,
      Column(
        children: List.generate(buttons, (_) => const ActionButton(action: CleanupLocalAlbumAction(albumId: albumId))),
      ),
      overrides: [driftProvider.overrideWithValue(drift), ...context.selected(selection)],
    );
  }

  Future<void> respond(WidgetTester tester, {required bool confirm}) async {
    // The launching action intentionally stays busy until the dialog resolves.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ConfirmDialog), findsOneWidget);
    final dialogButtons = find.descendant(of: find.byType(ConfirmDialog), matching: find.byType(TextButton));
    await tester.tap(dialogButtons.at(confirm ? 1 : 0));
    await tester.pumpAndSettle();
  }

  testWidgets('the real album page menu is reachable without selecting a photo', (tester) async {
    final factory = _MockTimelineFactory();
    when(
      () => factory.localAlbum(
        albumId: albumId,
        groupBy: any(named: 'groupBy'),
        temporalScope: any(named: 'temporalScope'),
      ),
    ).thenAnswer(
      (_) => TimelineService((
        assetSource: (_, _) async => const [],
        bucketSource: () => Stream.value(const []),
        origin: TimelineOrigin.localAlbum,
      )),
    );
    await tester.pumpTestWidget(
      context,
      withStubRouter(
        LocalTimelinePage(
          album: LocalAlbum(id: albumId, name: 'Camera', updatedAt: DateTime(2026)),
        ),
      ),
      overrides: [driftProvider.overrideWithValue(drift), timelineFactoryProvider.overrideWithValue(factory)],
    );
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();

    expect(
      find.text('Delete 2 items in this album from this device? Server copies will not be changed.'),
      findsOneWidget,
    );
    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any()));
    await respond(tester, confirm: false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('counted confirmation precedes device-only deletion of the actual album snapshot', (tester) async {
    await pumpAction(tester);
    await tester.tap(find.text(label));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('Delete 2 items in this album from this device? Server copies will not be changed.'),
      findsOneWidget,
    );
    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any()));
    await respond(tester, confirm: true);

    verify(
      () => context.service.cleanup.service.deleteLocalAssetsDetailed(assets.map((asset) => asset.id).toList()),
    ).called(1);
    expect(find.textContaining('2 removed, 0 remain'), findsOneWidget);
  });

  testWidgets('cancelling the album confirmation does not request MediaStore cleanup', (tester) async {
    await pumpAction(tester);
    await tester.tap(find.text(label));
    await respond(tester, confirm: false);

    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any()));
    verify(() => repository.getAssets(albumId)).called(1);
  });

  testWidgets('an empty album does not prompt or delete unrelated files', (tester) async {
    assets = [];
    await pumpAction(tester);
    await tester.tap(find.text(label));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(ConfirmDialog), findsNothing);
    expect(find.text('No assets to show'), findsOneWidget);
    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any()));
  });

  testWidgets('partial native success keeps rejected and unrelated selection available', (tester) async {
    final rejected = assets[1];
    final cloudOnly = RemoteAssetFactory.create(ownerId: context.currentUser.id);
    when(
      () => context.service.cleanup.service.deleteLocalAssetsDetailed(any()),
    ).thenAnswer((_) async => LocalDeletionResult(deletedIds: [assets[0].id], remainingIds: [rejected.id]));
    await pumpAction(tester, selection: {...assets, cloudOnly});
    final container = ProviderScope.containerOf(tester.element(find.byType(ActionButton)), listen: false);
    await tester.tap(find.text(label));
    await respond(tester, confirm: true);

    expect(container.read(multiSelectProvider).selectedAssets, {rejected, cloudOnly});
    expect(find.textContaining('1 removed, 1 remain'), findsOneWidget);
  });

  testWidgets('system rejection retains the complete album selection', (tester) async {
    when(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any())).thenAnswer(
      (_) async => LocalDeletionResult(deletedIds: const [], remainingIds: assets.map((asset) => asset.id).toList()),
    );
    await pumpAction(tester, selection: assets.toSet());
    final container = ProviderScope.containerOf(tester.element(find.byType(ActionButton)), listen: false);
    await tester.tap(find.text(label));
    await respond(tester, confirm: true);

    expect(container.read(multiSelectProvider).selectedAssets, assets.toSet());
    expect(find.textContaining('0 removed, 2 remain'), findsOneWidget);
  });

  testWidgets('a repeated request while confirmation is visible shares one guarded operation', (tester) async {
    final callbacks = <FutureOr<void> Function()>[];
    // Retain a second actual action callback, as a menu/toolbar can do while a
    // modal covers its button. Both must share the Timeline cleanup guard.
    await tester.pumpTestWidget(
      context,
      Consumer(
        builder: (context, ref, _) {
          callbacks.clear();
          callbacks.add(const CleanupLocalAlbumAction(albumId: albumId).create(context, ref).onAction);
          callbacks.add(const CleanupLocalAlbumAction(albumId: albumId).create(context, ref).onAction);
          return const ActionButton(action: CleanupLocalAlbumAction(albumId: albumId));
        },
      ),
      overrides: [driftProvider.overrideWithValue(drift)],
    );
    final first = Future<void>.sync(callbacks.first);
    await tester.pumpAndSettle();
    final second = Future<void>.sync(callbacks.last);
    await tester.pump();
    expect(find.byType(ConfirmDialog), findsOneWidget);
    verify(() => repository.getAssets(albumId)).called(1);
    await respond(tester, confirm: false);
    await Future.wait([first, second]);
    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any()));
  });

  testWidgets('new, moved and changed IDs during confirmation never expand the accepted snapshot', (tester) async {
    final original = assets;
    await pumpAction(tester);
    await tester.tap(find.text(label));
    await tester.pump(const Duration(milliseconds: 300));
    assets = [original[0], original[1].copyWith(name: 'replacement-with-reused-id.jpg'), LocalAssetFactory.create()];
    await respond(tester, confirm: true);

    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed([original[0].id])).called(1);
    expect(find.textContaining('1 removed, 1 remain'), findsOneWidget);
  });

  testWidgets('switching server while confirmation is open prevents the old request', (tester) async {
    await pumpAction(tester);
    await tester.tap(find.text(label));
    await tester.pump(const Duration(milliseconds: 300));
    await StoreService.I.put(StoreKey.serverEndpoint, 'https://other.example.test/api');
    await respond(tester, confirm: true);

    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any()));
    verify(() => repository.getAssets(albumId)).called(1);
  });

  testWidgets('a checksum-only revision change cannot delete the replacement file', (tester) async {
    assets = [LocalAssetFactory.create()];
    await pumpAction(tester);
    await tester.tap(find.text(label));
    await tester.pump(const Duration(milliseconds: 300));
    assets = [assets.single.copyWith(checksum: 'changed-revision')];
    await respond(tester, confirm: true);

    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any()));
    expect(find.textContaining('0 removed, 1 remain'), findsOneWidget);
  });

  testWidgets('an item moved out of the album is retained while a newly arrived item is not selected', (tester) async {
    final original = assets;
    await pumpAction(tester);
    await tester.tap(find.text(label));
    await tester.pump(const Duration(milliseconds: 300));
    assets = [original[0], LocalAssetFactory.create()];
    await respond(tester, confirm: true);

    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed([original[0].id])).called(1);
    expect(find.textContaining('1 removed, 1 remain'), findsOneWidget);
  });

  testWidgets('album-wide cleanup cannot overlap an already pending selected-device operation', (tester) async {
    final pending = Completer<LocalDeletionResult>();
    when(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any())).thenAnswer((_) => pending.future);
    await tester.pumpTestWidget(
      context,
      const Column(
        children: [
          ActionButton(action: CleanupLocalAction(source: .timeline)),
          ActionButton(action: CleanupLocalAlbumAction(albumId: albumId)),
        ],
      ),
      overrides: [driftProvider.overrideWithValue(drift), ...context.selected(assets.toSet())],
    );
    await tester.tap(find.text('Delete from Device'));
    await tester.pump();
    await tester.tap(find.text(label));
    await tester.pump();

    verifyNever(() => repository.getAssets(any()));
    verify(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any())).called(1);
    pending.complete(LocalDeletionResult(deletedIds: const [], remainingIds: assets.map((asset) => asset.id).toList()));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmDialog), findsNothing);
  });

  testWidgets('closing the album during asynchronous snapshot lookup makes no native request', (tester) async {
    final pending = Completer<List<LocalAsset>>();
    when(() => repository.getAssets(albumId)).thenAnswer((_) => pending.future);
    await pumpAction(tester);
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(assets);
    await tester.pump();

    verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any()));
    expect(tester.takeException(), isNull);
  });
}
