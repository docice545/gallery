import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/face_aware_thumbnail_scope.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/local_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_framing.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/timeline_thumbnail_request.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_autoplay.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_scope.widget.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/thumbnail_framing.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../service.mocks.dart';
import '../../../test_utils.dart';
import '../../../widget_tester_extensions.dart';

const _topFace = Rect.fromLTRB(0.32, 0.02, 0.64, 0.20);
const _bottomFace = Rect.fromLTRB(0.32, 0.90, 0.64, 0.99);
const _tileKey = Key('quality-tile');

class _TileViewport {
  const _TileViewport({this.size = const Size.square(180), this.dpr = 3});

  final Size size;
  final double dpr;
}

RemoteAsset _remote({String id = 'quality-photo', int? width = 4000, int? height = 6000, bool motion = false}) {
  final asset = TestUtils.createRemoteAsset(id: id, width: width, height: height);
  return motion ? asset.copyWith(livePhotoVideoId: '$id-video') : asset;
}

void _expectAspectCorrectBounded(Size size, BaseAsset asset) {
  expect(size.width, greaterThan(0));
  expect(size.height, greaterThan(0));
  expect(size.longestSide, lessThanOrEqualTo(1440));
  expect(size.width / size.height, closeTo(asset.width! / asset.height!, 1e-9));
}

void _expectPreview(RemoteImageProvider provider) {
  final uri = Uri.parse(provider.url);
  expect(uri.path, endsWith('/thumbnail'));
  expect(uri.queryParameters['size'], 'preview');
  expect(provider, isNot(isA<RemoteFullImageProvider>()));
}

// The production image request takes ownership of this allocation and frees it
// after creating the immutable buffer. A small decoded image lets lifecycle
// tests inspect a completed Flutter cache entry without HTTP or an image plugin.
List<Object?> _decodedReply() {
  const width = 9;
  const height = 16;
  const length = width * height * 4;
  final pointer = malloc<Uint8>(length);
  final pixels = pointer.asTypedList(length);
  for (var index = 0; index < length; index += 4) {
    pixels.setRange(index, index + 4, const [32, 64, 128, 255]);
  }
  return [
    <Object?, Object?>{'pointer': pointer.address, 'width': width, 'height': height, 'rowBytes': width * 4},
  ];
}

void _qualityTestWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await callback(tester);
    } finally {
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  late Drift db;
  late MockAssetService assetService;
  late HttpOverrides? previousHttpOverrides;
  var returnDecodedImage = false;
  final remoteRequests = <List<Object?>>[];
  final localRequests = <List<Object?>>[];
  const remoteRequest = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const remoteCancel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );
  const localRequest = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.LocalImageApi.requestImage',
    LocalImageApi.pigeonChannelCodec,
  );
  const localCancel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.LocalImageApi.cancelRequest',
    LocalImageApi.pigeonChannelCodec,
  );

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    previousHttpOverrides = HttpOverrides.current;
    TestUtils.init();
    registerFallbackValue(_remote());
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await SettingsRepository.ensureInitialized(db);
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await Store.put(StoreKey.serverEndpoint, 'https://example.test/api');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(remoteRequest, (message) async {
      remoteRequests.add((message! as List<Object?>).toList());
      return returnDecodedImage ? _decodedReply() : <Object?>[null];
    });
    messenger.setMockDecodedMessageHandler(remoteCancel, (_) async => <Object?>[null]);
    messenger.setMockDecodedMessageHandler(localRequest, (message) async {
      localRequests.add((message! as List<Object?>).toList());
      return returnDecodedImage ? _decodedReply() : <Object?>[null];
    });
    messenger.setMockDecodedMessageHandler(localCancel, (_) async => <Object?>[null]);
  });

  setUp(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    remoteRequests.clear();
    localRequests.clear();
    returnDecodedImage = false;
    await SettingsRepository.instance.clear(SettingsKey.values);
    assetService = MockAssetService();
    // Keep source preparation pending at the service boundary. This exercises
    // the real motion layout, whose Linux platform view is a placeholder, while
    // avoiding storage/network/native-player setup irrelevant to tile geometry.
    when(() => assetService.getAsset(any())).thenAnswer((_) => Completer<BaseAsset?>().future);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDownAll(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(remoteRequest, null);
    messenger.setMockDecodedMessageHandler(remoteCancel, null);
    messenger.setMockDecodedMessageHandler(localRequest, null);
    messenger.setMockDecodedMessageHandler(localCancel, null);
    await Store.clear();
    await SettingsRepository.reset();
    await db.close();
    HttpOverrides.global = previousHttpOverrides;
  });

  Future<void> mountTile(
    WidgetTester tester,
    BaseAsset asset, {
    Stream<List<Rect>> Function()? faces,
    bool faceScope = true,
    bool motionScope = false,
    BoxFit fit = BoxFit.cover,
    _TileViewport viewport = const _TileViewport(),
    ValueNotifier<_TileViewport>? changingViewport,
    VoidCallback? onTap,
  }) async {
    Widget tile(_TileViewport value) => Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(devicePixelRatio: value.dpr),
        child: Center(
          child: SizedBox.fromSize(
            size: value.size,
            child: GestureDetector(
              key: _tileKey,
              onTap: onTap,
              child: ThumbnailTile(asset, fit: fit, heroOffset: 7),
            ),
          ),
        ),
      ),
    );
    Widget child = changingViewport == null
        ? tile(viewport)
        : ValueListenableBuilder<_TileViewport>(
            valueListenable: changingViewport,
            builder: (_, value, _) => tile(value),
          );
    if (faceScope) {
      child = FaceAwareThumbnailScope(child: child);
    }
    if (motionScope) {
      child = TimelineLivePhotoScope(child: child);
    }
    await tester.pumpConsumerWidgetRaw(
      child,
      overrides: [
        assetServiceProvider.overrideWithValue(assetService),
        thumbnailFaceBoundsProvider.overrideWith((_, _) => faces?.call() ?? Stream.value(const [])),
      ],
    );
    await tester.pump();
  }

  Thumbnail still(WidgetTester tester) => tester.widget<Thumbnail>(find.byType(Thumbnail));

  Future<void> startPreview(WidgetTester tester) async {
    await tester.pump(livePhotoSettlingDelay);
    await tester.pump();
    expect(find.byType(NativeVideoViewer), findsOneWidget);
  }

  void expectNoOriginalRequests() {
    expect(remoteRequests.isNotEmpty || localRequests.isNotEmpty, isTrue);
    for (final request in remoteRequests) {
      expect(Uri.parse(request[0]! as String).path, endsWith('/thumbnail'));
      expect(request[2], isFalse, reason: 'timeline stills use a one-frame thumbnail request');
    }
    for (final request in localRequests) {
      expect(request[2], greaterThan(0));
      expect(request[3], greaterThan(0));
      expect(request[5], isFalse);
    }
  }

  for (final dimensions in [const Size(4000, 6000), const Size(6000, 4000)]) {
    _qualityTestWidgets(
      'high-DPR $dimensions remote still chooses preview and sends bounded physical decode dimensions',
      (tester) async {
        final asset = _remote(width: dimensions.width.toInt(), height: dimensions.height.toInt());
        await SettingsRepository.instance.write(SettingsKey.imageLoadOriginal, true);
        await mountTile(tester, asset);

        final provider = still(tester).imageProvider! as RemoteImageProvider;
        _expectPreview(provider);
        _expectAspectCorrectBounded(provider.decodeSize!, asset);
        expect(provider.decodeSize!.shortestSide, greaterThanOrEqualTo(180 * 3));
        expect(remoteRequests.single[3], provider.decodeSize!.width.ceil());
        expect(remoteRequests.single[4], provider.decodeSize!.height.ceil());
        expect(still(tester).framingImageSize, dimensions);
        expectNoOriginalRequests();
        expect(tester.takeException(), isNull);
      },
    );
  }

  _qualityTestWidgets('remote panorama decode remains bounded rather than following its cover overscan', (
    tester,
  ) async {
    final asset = _remote(width: 8000, height: 1000);
    await mountTile(tester, asset);

    final provider = still(tester).imageProvider! as RemoteImageProvider;
    _expectPreview(provider);
    _expectAspectCorrectBounded(provider.decodeSize!, asset);
    expect(provider.decodeSize!.longestSide, 1440);
    expect(remoteRequests.single[3], lessThanOrEqualTo(1440));
    expect(remoteRequests.single[4], lessThanOrEqualTo(1440));
    expectNoOriginalRequests();
  });

  _qualityTestWidgets('small square remote tile retains the cheaper thumbnail source', (tester) async {
    final asset = _remote(width: 2000, height: 2000);
    await mountTile(tester, asset, viewport: const _TileViewport(size: Size.square(100), dpr: 1));

    final provider = still(tester).imageProvider! as RemoteImageProvider;
    expect(Uri.parse(provider.url).queryParameters['size'], 'thumbnail');
    _expectAspectCorrectBounded(provider.decodeSize!, asset);
    expect(provider.decodeSize!.shortestSide, greaterThanOrEqualTo(100));
    expect(provider.decodeSize!.longestSide, lessThanOrEqualTo(250));
    expectNoOriginalRequests();
  });

  for (final dimensions in [const Size(4000, 6000), const Size(6000, 4000)]) {
    _qualityTestWidgets(
      'scoped local $dimensions request exceeds 320 and preserves full-source aspect before faces arrive',
      (tester) async {
        final faces = StreamController<List<Rect>>();
        addTearDown(faces.close);
        final asset = TestUtils.createLocalAsset(
          id: 'local-quality-photo',
          remoteId: 'remote-quality-photo',
          width: dimensions.width.toInt(),
          height: dimensions.height.toInt(),
        );
        await mountTile(tester, asset, faces: () => faces.stream);

        final before = still(tester).imageProvider! as LocalThumbProvider;
        _expectAspectCorrectBounded(before.size, asset);
        expect(before.size.shortestSide, greaterThanOrEqualTo(180 * 3));
        expect(before.size.longestSide, greaterThan(320));
        expect(localRequests.single.sublist(2, 4), [before.size.width.ceil(), before.size.height.ceil()]);
        expect(localRequests.single[2]! as int, closeTo(before.size.width, 1));
        expect(localRequests.single[3]! as int, closeTo(before.size.height, 1));

        faces.add(const [_topFace]);
        await tester.pump();
        await tester.pump();
        expect(still(tester).imageProvider, before);
        expect(localRequests, hasLength(1), reason: 'face arrival must not change the image request or cache key');
        expect(still(tester).framingImageSize, dimensions);
        expect(still(tester).faces, const [_topFace]);
        expectNoOriginalRequests();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final dimensions in [const Size(30000, 10), const Size(10, 30000)]) {
    _qualityTestWidgets('ultra-thin local $dimensions preserves positive bounded Pigeon axes', (tester) async {
      final asset = TestUtils.createLocalAsset(
        id: 'ultra-thin-local',
        width: dimensions.width.toInt(),
        height: dimensions.height.toInt(),
      );
      await mountTile(tester, asset);

      final provider = still(tester).imageProvider! as LocalThumbProvider;
      _expectAspectCorrectBounded(provider.size, asset);
      expect(provider.size.longestSide, 1440);
      expect(provider.size.shortestSide, lessThan(1));
      expect(localRequests, hasLength(1));
      final axes = localRequests.single.sublist(2, 4).cast<int>();
      expect(axes, everyElement(inInclusiveRange(1, 1440)));
      expect(axes, [provider.size.width.ceil(), provider.size.height.ceil()]);
      expectNoOriginalRequests();
      expect(tester.takeException(), isNull);
    });
  }

  _qualityTestWidgets('ordinary and Live Photo stills use the same scoped quality and canonical source geometry', (
    tester,
  ) async {
    final ordinary = _remote(id: 'ordinary-photo');
    final motion = _remote(id: 'motion-photo', motion: true);
    await tester.pumpConsumerWidgetRaw(
      FaceAwareThumbnailScope(
        child: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(devicePixelRatio: 3),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(dimension: 180, child: ThumbnailTile(ordinary)),
                  SizedBox.square(dimension: 180, child: ThumbnailTile(motion)),
                ],
              ),
            ),
          ),
        ),
      ),
      overrides: [
        thumbnailFaceBoundsProvider.overrideWith((_, _) => Stream.value(const [_topFace])),
      ],
    );
    await tester.pump();

    final thumbnails = tester.widgetList<Thumbnail>(find.byType(Thumbnail)).toList();
    final ordinaryProvider = thumbnails[0].imageProvider! as RemoteImageProvider;
    final motionProvider = thumbnails[1].imageProvider! as RemoteImageProvider;
    _expectPreview(ordinaryProvider);
    _expectPreview(motionProvider);
    expect(ordinaryProvider.decodeSize, motionProvider.decodeSize);
    expect(thumbnails[0].framingImageSize, thumbnails[1].framingImageSize);
    final overlay = tester.widget<TimelineLivePhotoTile>(find.byType(TimelineLivePhotoTile));
    expect(overlay.framingImageSize, thumbnails[1].framingImageSize);
    expect(overlay.faces, thumbnails[1].faces);
    expectNoOriginalRequests();
  });

  _qualityTestWidgets('real motion FittedBox and still receive matching face-aware framing geometry', (tester) async {
    final asset = _remote(motion: true);
    await mountTile(tester, asset, motionScope: true, faces: () => Stream.value(const [_topFace]));
    await startPreview(tester);

    final thumbnail = still(tester);
    final overlay = tester.widget<TimelineLivePhotoTile>(find.byType(TimelineLivePhotoTile));
    expect(overlay.framingImageSize, thumbnail.framingImageSize);
    expect(overlay.faces, thumbnail.faces);
    final viewport = tester.getSize(find.byType(TimelineLivePhotoTile));
    final expected = faceAwareThumbnailFraming(
      imageSize: thumbnail.framingImageSize!,
      viewportSize: viewport,
      faces: thumbnail.faces,
    );
    final fitted = tester.widget<FittedBox>(
      find.ancestor(of: find.byType(NativeVideoViewer), matching: find.byType(FittedBox)),
    );
    expect(fitted.fit, expected.fit);
    expect(fitted.alignment, expected.alignment);
    final nativePreview = tester.widget<NativeVideoViewer>(find.byType(NativeVideoViewer));
    expect(nativePreview.timelinePreviewImageSize, thumbnail.framingImageSize);
    expect(nativePreview.timelinePreviewAlignment, fitted.alignment);
    final request = buildTimelineThumbnailRequest(
      viewportSize: viewport,
      devicePixelRatio: 3,
      imageSize: thumbnail.framingImageSize,
      faces: thumbnail.faces,
    );
    expect(nativePreview.timelinePreviewRequiredSize, request.requiredSize);
    expect(nativePreview.timelinePreviewRequiredSize, const Size(540, 810));
    expect((thumbnail.imageProvider! as RemoteImageProvider).decodeSize, request.decodeSize);
    expect(
      request.requiredSize,
      isNot(request.decodeSize),
      reason: 'playback does not require extra cache bucket pixels',
    );
    expect(tester.getSize(find.byType(NativeVideoViewer)), const Size(180, 270));
    expect(tester.widget<Hero>(find.byType(Hero)).tag, '${asset.heroTag}_7');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  _qualityTestWidgets('real motion uses the shared contain canvas when separated faces cannot fit cover', (
    tester,
  ) async {
    await mountTile(
      tester,
      _remote(motion: true),
      motionScope: true,
      faces: () => Stream.value(const [_topFace, _bottomFace]),
    );
    await startPreview(tester);

    final fitted = tester.widget<FittedBox>(
      find.ancestor(of: find.byType(NativeVideoViewer), matching: find.byType(FittedBox)),
    );
    expect(fitted.fit, BoxFit.contain);
    expect(fitted.alignment, Alignment.center);
    final thumbnail = still(tester);
    final framing = faceAwareThumbnailFraming(
      imageSize: thumbnail.framingImageSize!,
      viewportSize: tester.getSize(find.byType(Thumbnail)),
      faces: thumbnail.faces,
    );
    expect(framing.fit, fitted.fit);
    expect(framing.alignment, fitted.alignment);
    final nativePreview = tester.widget<NativeVideoViewer>(find.byType(NativeVideoViewer));
    expect(nativePreview.timelinePreviewImageSize, thumbnail.framingImageSize);
    expect(nativePreview.timelinePreviewAlignment, fitted.alignment);
    final request = buildTimelineThumbnailRequest(
      viewportSize: tester.getSize(find.byType(Thumbnail)),
      devicePixelRatio: 3,
      imageSize: thumbnail.framingImageSize,
      faces: thumbnail.faces,
    );
    expect(nativePreview.timelinePreviewRequiredSize, request.requiredSize);
    expect(nativePreview.timelinePreviewRequiredSize, const Size(360, 540));
    expect((thumbnail.imageProvider! as RemoteImageProvider).decodeSize, request.decodeSize);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  _qualityTestWidgets('separated face arrival selects an adequate thumbnail while preserving the active motion lease', (
    tester,
  ) async {
    final faces = StreamController<List<Rect>>();
    addTearDown(faces.close);
    final asset = _remote(width: 4000, height: 16000, motion: true);
    await mountTile(tester, asset, motionScope: true, faces: () => faces.stream);
    final before = still(tester).imageProvider! as RemoteImageProvider;
    _expectPreview(before);
    await startPreview(tester);
    final stillState = tester.state(find.byType(Thumbnail));
    final previewState = tester.state(find.byType(NativeVideoViewer));

    faces.add(const [_topFace, _bottomFace]);
    await tester.pump();
    await tester.pump();

    final thumbnail = still(tester);
    final after = thumbnail.imageProvider! as RemoteImageProvider;
    expect(Uri.parse(after.url).queryParameters['size'], 'thumbnail');
    expect(after, isNot(before), reason: 'contain needs fewer source pixels than the preceding cover crop');
    _expectAspectCorrectBounded(after.decodeSize!, asset);
    expect(tester.state(find.byType(Thumbnail)), same(stillState));
    expect(tester.state(find.byType(NativeVideoViewer)), same(previewState));
    final fitted = tester.widget<FittedBox>(
      find.ancestor(of: find.byType(NativeVideoViewer), matching: find.byType(FittedBox)),
    );
    expect(fitted.fit, BoxFit.contain);
    final request = buildTimelineThumbnailRequest(
      viewportSize: tester.getSize(find.byType(Thumbnail)),
      devicePixelRatio: 3,
      imageSize: thumbnail.framingImageSize,
      faces: thumbnail.faces,
    );
    final nativePreview = tester.widget<NativeVideoViewer>(find.byType(NativeVideoViewer));
    expect(nativePreview.timelinePreviewRequiredSize, request.requiredSize);
    expect(after.decodeSize, request.decodeSize);
    expect(after.decodeSize!.width, greaterThanOrEqualTo(135));
    expect(after.decodeSize!.height, greaterThanOrEqualTo(540));
    expectNoOriginalRequests();

    nativePreview.onPreviewCompleted!();
    await tester.pump();
    faces.add(const [_topFace]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(NativeVideoViewer), findsNothing, reason: 'new source quality must not rearm a consumed lease');
    _expectPreview(still(tester).imageProvider! as RemoteImageProvider);
    expectNoOriginalRequests();
    expect(tester.takeException(), isNull);
  });

  _qualityTestWidgets(
    'completed still cache entry and provider survive motion start, face arrival and one-shot completion',
    (tester) async {
      returnDecodedImage = true;
      final faces = StreamController<List<Rect>>();
      addTearDown(faces.close);
      await mountTile(tester, _remote(motion: true), motionScope: true, faces: () => faces.stream);
      await tester.runAsync(() => pumpEventQueue(times: 30));
      await tester.pump(const Duration(milliseconds: 120));
      final provider = still(tester).imageProvider! as RemoteImageProvider;
      final state = tester.state(find.byType(Thumbnail));
      final cache = PaintingBinding.instance.imageCache;
      expect(cache.statusForKey(provider).keepAlive, isTrue);
      final requests = remoteRequests.length;

      await startPreview(tester);
      expect(still(tester).imageProvider, provider);
      expect(tester.state(find.byType(Thumbnail)), same(state));
      expect(cache.statusForKey(provider).keepAlive, isTrue);
      final previewState = tester.state(find.byType(NativeVideoViewer));

      faces.add(const [_topFace]);
      await tester.pump();
      await tester.pump();
      expect(still(tester).imageProvider, provider);
      expect(tester.state(find.byType(NativeVideoViewer)), same(previewState));
      expect(cache.statusForKey(provider).keepAlive, isTrue);
      expect(remoteRequests, hasLength(requests));

      tester.widget<NativeVideoViewer>(find.byType(NativeVideoViewer)).onPreviewCompleted!();
      await tester.pump();
      expect(find.byType(NativeVideoViewer), findsNothing);
      expect(still(tester).imageProvider, provider);
      expect(tester.state(find.byType(Thumbnail)), same(state));
      expect(cache.statusForKey(provider).keepAlive, isTrue);

      faces.add(const [_bottomFace]);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(NativeVideoViewer), findsNothing, reason: 'face repaint must not rearm one-shot autoplay');
      expect(still(tester).imageProvider, provider);
      expect(remoteRequests, hasLength(requests));
      expectNoOriginalRequests();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  _qualityTestWidgets('DPR and logical tile resize replace the bounded provider key while preserving Thumbnail state', (
    tester,
  ) async {
    final viewport = ValueNotifier(const _TileViewport(size: Size.square(100), dpr: 1));
    addTearDown(viewport.dispose);
    await mountTile(tester, _remote(), changingViewport: viewport);
    final initial = still(tester).imageProvider! as RemoteImageProvider;
    final state = tester.state(find.byType(Thumbnail));

    viewport.value = const _TileViewport(size: Size.square(100), dpr: 3);
    await tester.pump();
    await tester.pump();
    final denser = still(tester).imageProvider! as RemoteImageProvider;
    expect(denser, isNot(initial));
    expect(denser.decodeSize!.shortestSide, greaterThan(initial.decodeSize!.shortestSide));
    _expectPreview(denser);
    expect(tester.state(find.byType(Thumbnail)), same(state));

    viewport.value = const _TileViewport(size: Size.square(220), dpr: 3);
    await tester.pump();
    await tester.pump();
    final larger = still(tester).imageProvider! as RemoteImageProvider;
    expect(larger, isNot(denser));
    expect(larger.decodeSize!.shortestSide, greaterThan(denser.decodeSize!.shortestSide));
    _expectAspectCorrectBounded(larger.decodeSize!, _remote());
    expect(tester.state(find.byType(Thumbnail)), same(state));
    expect(remoteRequests, hasLength(3));
    expectNoOriginalRequests();
    expect(tester.takeException(), isNull);
  });

  _qualityTestWidgets('autoplay disabled keeps the same scoped high-quality still provider', (tester) async {
    await SettingsRepository.instance.write(SettingsKey.timelineAutoplayLivePhotos, false);
    await mountTile(tester, _remote(motion: true), motionScope: true);
    final provider = still(tester).imageProvider! as RemoteImageProvider;
    _expectPreview(provider);
    await tester.pump(const Duration(seconds: 2));

    expect(find.byType(NativeVideoViewer), findsNothing);
    expect(still(tester).imageProvider, provider);
    expect(remoteRequests, hasLength(1));
    expectNoOriginalRequests();
    expect(tester.takeException(), isNull);
  });

  for (final edited in [true, false]) {
    _qualityTestWidgets(
      '${edited ? 'edited' : 'unknown-geometry'} main-timeline Live Photo stays sharp and cannot cascade or rearm after metadata updates',
      (tester) async {
        final initial = edited
            ? _remote(id: 'fallback-live-photo', motion: true).copyWith(isEdited: true)
            : _remote(id: 'fallback-live-photo', width: null, height: null, motion: true);
        final changingAsset = ValueNotifier<BaseAsset>(initial);
        addTearDown(changingAsset.dispose);
        final other = _remote(id: 'other-visible-live-photo', motion: true);
        await tester.pumpConsumerWidgetRaw(
          FaceAwareThumbnailScope(
            child: TimelineLivePhotoScope(
              child: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(devicePixelRatio: 3),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 180,
                          child: ValueListenableBuilder<BaseAsset>(
                            valueListenable: changingAsset,
                            builder: (_, asset, _) => ThumbnailTile(asset),
                          ),
                        ),
                        SizedBox.square(dimension: 180, child: ThumbnailTile(other)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          overrides: [
            assetServiceProvider.overrideWithValue(assetService),
            thumbnailFaceBoundsProvider.overrideWith((_, _) => Stream.value(const [_topFace])),
          ],
        );
        await tester.pump();
        final initialThumbnails = tester.widgetList<Thumbnail>(find.byType(Thumbnail)).toList();
        final initialProvider = initialThumbnails.first.imageProvider! as RemoteImageProvider;
        final otherProvider = initialThumbnails.last.imageProvider! as RemoteImageProvider;
        _expectPreview(initialProvider);
        expect(initialProvider.decodeSize!.shortestSide, greaterThanOrEqualTo(180 * 3));
        expect(initialProvider.decodeSize!.longestSide, lessThanOrEqualTo(1440));
        expect(initialThumbnails.first.framingImageSize, isNull);
        final overlays = tester.widgetList<TimelineLivePhotoTile>(find.byType(TimelineLivePhotoTile)).toList();
        expect(overlays.first.requireMatchingFraming, isTrue);
        expect(overlays.first.framingImageSize, isNull);

        await tester.pump(livePhotoSettlingDelay);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(NativeVideoViewer), findsNothing);
        verifyNever(() => assetService.getAsset(any()));
        final afterFallback = tester.widgetList<Thumbnail>(find.byType(Thumbnail)).toList();
        expect(afterFallback.first.imageProvider, initialProvider);
        expect(afterFallback.last.imageProvider, otherProvider);

        changingAsset.value = initial.copyWith(isEdited: false, width: 4000, height: 6000);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        final afterMetadata = tester.widgetList<Thumbnail>(find.byType(Thumbnail)).toList();
        expect(afterMetadata.first.framingImageSize, const Size(4000, 6000));
        _expectPreview(afterMetadata.first.imageProvider! as RemoteImageProvider);
        expect(afterMetadata.last.imageProvider, otherProvider);
        expect(
          find.byType(NativeVideoViewer),
          findsNothing,
          reason: 'static fallback consumes the viewport reservation',
        );
        verifyNever(() => assetService.getAsset(any()));
        expectNoOriginalRequests();
        expect(tester.takeException(), isNull);
      },
    );
  }

  _qualityTestWidgets('scroll activity stops motion while retaining the still request and completed viewport lease', (
    tester,
  ) async {
    await mountTile(tester, _remote(motion: true), motionScope: true);
    final provider = still(tester).imageProvider! as RemoteImageProvider;
    final state = tester.state(find.byType(Thumbnail));
    await startPreview(tester);
    final context = tester.element(find.byType(ThumbnailTile));
    final metrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: 0,
      viewportDimension: 600,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 3,
    );
    ScrollStartNotification(metrics: metrics, context: context).dispatch(context);
    await tester.pump();

    expect(find.byType(NativeVideoViewer), findsNothing);
    expect(still(tester).imageProvider, provider);
    expect(tester.state(find.byType(Thumbnail)), same(state));
    ScrollEndNotification(metrics: metrics, context: context).dispatch(context);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(NativeVideoViewer), findsNothing);
    expect(remoteRequests, hasLength(1));
    expectNoOriginalRequests();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  _qualityTestWidgets('ordinary photo is ineligible for motion and retains its high-quality still', (tester) async {
    await mountTile(tester, _remote(), motionScope: true);
    final provider = still(tester).imageProvider! as RemoteImageProvider;
    _expectPreview(provider);
    await tester.pump(const Duration(seconds: 2));

    expect(find.byType(TimelineLivePhotoTile), findsNothing);
    expect(find.byType(NativeVideoViewer), findsNothing);
    expect(still(tester).imageProvider, provider);
    expect(remoteRequests, hasLength(1));
    expectNoOriginalRequests();
  });

  _qualityTestWidgets(
    'outside the face scope retains default remote thumbnail requests and avoids metadata subscriptions',
    (tester) async {
      var subscriptions = 0;
      await mountTile(
        tester,
        _remote(motion: true),
        faceScope: false,
        faces: () {
          subscriptions++;
          return Stream.value(const [_topFace]);
        },
      );
      final provider = still(tester).imageProvider! as RemoteImageProvider;

      expect(Uri.parse(provider.url).queryParameters['size'], 'thumbnail');
      expect(provider.decodeSize, isNull);
      expect(still(tester).framingImageSize, isNull);
      expect(remoteRequests.single.sublist(3, 5), [null, null]);
      expect(subscriptions, 0);
      expect(still(tester).faces, isEmpty);
      expectNoOriginalRequests();
    },
  );
}
