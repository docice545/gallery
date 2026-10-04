import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_scope.widget.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

import '../../../test_utils.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../widget_tester_extensions.dart';

void main() {
  late Drift db;
  late int taps;
  late int previews;
  const previewKey = Key('live-preview');
  const tileKey = Key('thumbnail-tap-target');
  const requestChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const cancelChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestUtils.init();
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await SettingsRepository.ensureInitialized(db);
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await Store.put(StoreKey.serverEndpoint, 'https://example.test/api');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(requestChannel, (_) async => <Object?>[null]);
    messenger.setMockDecodedMessageHandler(cancelChannel, (_) async => <Object?>[null]);
  });

  setUp(() async {
    taps = 0;
    previews = 0;
    await SettingsRepository.instance.clear(SettingsKey.values);
  });

  tearDownAll(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(requestChannel, null);
    messenger.setMockDecodedMessageHandler(cancelChannel, null);
    await Store.clear();
    await SettingsRepository.reset();
    await db.close();
  });

  Future<void> mountTile(WidgetTester tester, RemoteAsset asset, {bool scope = true}) async {
    final tile = Consumer(
      builder: (context, ref, _) => Center(
        child: SizedBox.square(
          dimension: 160,
          child: GestureDetector(
            key: tileKey,
            onTap: () => taps++,
            onLongPress: () => ref.read(multiSelectProvider.notifier).toggleAssetSelection(asset),
            child: ThumbnailTile(asset, showStackIndicator: true, heroOffset: 7),
          ),
        ),
      ),
    );
    await tester.pumpConsumerWidget(
      scope
          ? TimelineLivePhotoScope(
              previewBuilder: (asset, onCompleted) {
                previews++;
                return const ColoredBox(key: previewKey, color: Colors.green);
              },
              child: tile,
            )
          : tile,
      overrides: [
        stackCountsProvider.overrideWith((_) => Stream.value({'stack1': 3})),
      ],
    );
  }

  testWidgets('autoplay overlays the real thumbnail while retaining its Hero, stack count and tap target', (
    tester,
  ) async {
    final asset = RemoteAssetFactory.create(stackId: 'stack1').copyWith(livePhotoVideoId: 'paired-video');
    await mountTile(tester, asset);
    final initialTileRect = tester.getRect(find.byKey(tileKey));
    final initialHeroRect = tester.getRect(find.byType(Hero));
    expect(find.byKey(previewKey), findsNothing);

    await tester.pump(const Duration(milliseconds: 351));
    await tester.pump();

    expect(find.byKey(previewKey), findsOneWidget);
    expect(find.byType(Thumbnail), findsOneWidget);
    expect(find.text(' 3'), findsOneWidget);
    expect(find.byIcon(Icons.burst_mode_rounded), findsOneWidget);
    expect(find.byIcon(Icons.motion_photos_on_rounded), findsOneWidget);
    expect(tester.widget<Hero>(find.byType(Hero)).tag, '${asset.heroTag}_7');
    expect(find.descendant(of: find.byType(Hero), matching: find.byKey(previewKey)), findsNothing);
    expect(tester.getRect(find.byKey(tileKey)), initialTileRect);
    expect(tester.getRect(find.byType(Hero)), initialHeroRect);

    await tester.tap(find.byKey(tileKey));
    await tester.pump();
    expect(taps, 1);
    expect(find.byKey(previewKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long press keeps normal selection decoration and badge while stopping motion', (tester) async {
    final asset = RemoteAssetFactory.create(stackId: 'stack1').copyWith(livePhotoVideoId: 'paired-video');
    await mountTile(tester, asset);
    await tester.pump(const Duration(milliseconds: 351));
    await tester.pump();
    expect(find.byKey(previewKey), findsOneWidget);

    await tester.longPress(find.byKey(tileKey));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.byType(ThumbnailTile)));
    expect(container.read(multiSelectProvider).selectedAssets, contains(asset));
    expect(find.byKey(previewKey), findsNothing);
    expect(find.text(' 3'), findsOneWidget);
    expect(tester.getSize(find.byType(Hero)), const Size.square(148));
    expect(find.byType(Thumbnail), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('motion thumbnails outside the main timeline scope stay static', (tester) async {
    final asset = RemoteAssetFactory.create().copyWith(livePhotoVideoId: 'paired-video');
    await mountTile(tester, asset, scope: false);
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(previewKey), findsNothing);
    expect(previews, 0);
    expect(find.byType(Thumbnail), findsOneWidget);
    expect(find.byType(Hero), findsOneWidget);
  });

  for (final type in [AssetType.image, AssetType.video]) {
    testWidgets('ordinary $type thumbnails keep their static grid and tap behavior', (tester) async {
      await mountTile(tester, RemoteAssetFactory.create(type: type));
      await tester.pump(const Duration(seconds: 1));

      expect(find.byKey(previewKey), findsNothing);
      expect(previews, 0);
      expect(find.byType(Thumbnail), findsOneWidget);
      expect(find.byType(Hero), findsOneWidget);
      await tester.tap(find.byKey(tileKey));
      expect(taps, 1);
    });
  }
}
