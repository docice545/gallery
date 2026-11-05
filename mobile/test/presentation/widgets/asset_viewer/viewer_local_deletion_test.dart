import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/bottom_bar.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/ocr.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

class _ViewerState extends AssetViewerStateNotifier {
  _ViewerState(this.asset);

  final BaseAsset? asset;

  @override
  AssetViewerState build() => AssetViewerState(currentAsset: asset);
}

class _Readonly extends ReadOnlyModeNotifier {
  @override
  bool build() => true;
}

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
    await StoreService.I.put(StoreKey.manageLocalMediaAndroid, false);
  });

  tearDown(() async {
    verifyNever(() => context.service.asset.service.deleteWithResults(any()));
    verifyNever(() => context.service.asset.service.acceptPermanentDeletion(any()));
    await context.dispose();
  });

  Future<void> pumpViewer(
    WidgetTester tester,
    BaseAsset? asset, {
    bool readonly = false,
    bool locked = false,
    TimelineOrigin origin = TimelineOrigin.main,
  }) async {
    if (asset != null) {
      when(() => context.service.asset.service.getAsset(asset)).thenAnswer((_) async => asset);
    }
    final timeline = TimelineService((
      assetSource: (_, _) async => [?asset],
      bucketSource: () => Stream.value(const []),
      origin: origin,
    ));
    addTearDown(timeline.dispose);
    await tester.pumpTestWidget(
      context,
      const ViewerBottomBar(),
      overrides: [
        assetViewerProvider.overrideWith(() => _ViewerState(asset)),
        timelineServiceProvider.overrideWithValue(timeline),
        inLockedViewProvider.overrideWithValue(locked),
        if (readonly) readonlyModeProvider.overrideWith(_Readonly.new),
        if (asset is RemoteAsset) ocrAssetProvider(asset.id).overrideWith((_) async => []),
      ],
    );
  }

  testWidgets('local-only viewer exposes device deletion; upload is in the preserved More menu', (tester) async {
    final asset = LocalAssetFactory.create(id: 'device-copy');

    await pumpViewer(tester, asset);

    expect(find.byTooltip('Upload'), findsNothing);
    expect(find.byTooltip('Google Lens'), findsOneWidget);
    expect(find.byTooltip(StaticTranslations.instance.delete_from_device), findsOneWidget);
    expect(find.byTooltip(StaticTranslations.instance.move_to_server_trash), findsNothing);
  });

  testWidgets('local-only device action uses existing cleanup and never deletes a server asset', (tester) async {
    final asset = LocalAssetFactory.create(id: 'device-copy');
    final cleanup = context.service.cleanup.service;
    when(
      () => cleanup.deleteLocalAssetsDetailed(any(), trash: true),
    ).thenAnswer((_) async => LocalDeletionResult(deletedIds: [asset.id], remainingIds: const []));
    await pumpViewer(tester, asset);

    await tester.tap(find.byTooltip(StaticTranslations.instance.delete_from_device));
    await tester.pumpAndSettle();

    verify(() => cleanup.deleteLocalAssetsDetailed([asset.id], trash: true)).called(1);
    verifyNever(() => context.service.asset.service.trash(any()));
    verifyNever(() => context.service.asset.service.restoreTrash(any()));
  });

  testWidgets('owned remote-only photo keeps cloud Trash without a device-delete action', (tester) async {
    final asset = RemoteAssetFactory.create(ownerId: context.currentUser.id);

    await pumpViewer(tester, asset);

    expect(find.byTooltip(StaticTranslations.instance.move_to_server_trash), findsOneWidget);
    expect(find.byTooltip(StaticTranslations.instance.delete_from_device), findsNothing);
    expect(find.byTooltip('Upload'), findsNothing);
  });

  testWidgets('owned merged photo keeps cloud Trash without changing its deletion mode', (tester) async {
    final asset = RemoteAssetFactory.create(ownerId: context.currentUser.id, localId: 'device-copy');

    await pumpViewer(tester, asset);

    expect(find.byTooltip(StaticTranslations.instance.move_to_server_trash), findsOneWidget);
    expect(find.byTooltip(StaticTranslations.instance.delete_from_device), findsNothing);
    expect(find.byTooltip('Upload'), findsNothing);
  });

  testWidgets('linked local asset keeps its existing cloud Trash action', (tester) async {
    final asset = LocalAssetFactory.create(remoteId: 'server-copy');

    await pumpViewer(tester, asset);

    expect(find.byTooltip(StaticTranslations.instance.move_to_server_trash), findsOneWidget);
    expect(find.byTooltip(StaticTranslations.instance.delete_from_device), findsNothing);
  });

  for (final localId in <String?>[null, 'foreign-device-copy']) {
    testWidgets('foreign remote photo with localId=$localId exposes no deletion action', (tester) async {
      final asset = RemoteAssetFactory.create(ownerId: 'another-user', localId: localId);

      await pumpViewer(tester, asset);

      expect(find.byTooltip(StaticTranslations.instance.move_to_server_trash), findsNothing);
      expect(find.byTooltip(StaticTranslations.instance.delete_from_device), findsNothing);
      verifyNever(() => context.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: true));
      verifyNever(() => context.service.asset.service.trash(any()));
    });
  }

  testWidgets('readonly viewer exposes no device-deletion action', (tester) async {
    await pumpViewer(tester, LocalAssetFactory.create(), readonly: true);

    expect(find.byTooltip(StaticTranslations.instance.delete_from_device), findsNothing);
    expect(find.byTooltip('Upload'), findsNothing);
  });

  testWidgets('locked viewer exposes no device-deletion action', (tester) async {
    await pumpViewer(tester, LocalAssetFactory.create(), locked: true);

    expect(find.byTooltip(StaticTranslations.instance.delete_from_device), findsNothing);
    expect(find.byTooltip('Upload'), findsNothing);
  });

  testWidgets('empty viewer exposes no deletion action', (tester) async {
    await pumpViewer(tester, null);

    expect(find.byTooltip(StaticTranslations.instance.delete_from_device), findsNothing);
    expect(find.byTooltip(StaticTranslations.instance.move_to_server_trash), findsNothing);
  });
}
