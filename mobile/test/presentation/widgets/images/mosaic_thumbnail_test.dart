import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/face_aware_thumbnail_scope.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_framing.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/timeline_thumbnail_request.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_autoplay.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_scope.widget.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/thumbnail_framing.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:openapi/api.dart' show AssetMediaSize;

import '../../../service.mocks.dart';
import '../../../test_utils.dart';
import '../../../widget_tester_extensions.dart';

const _separatedFaces = [Rect.fromLTRB(.3, .01, .6, .2), Rect.fromLTRB(.3, .8, .6, .99)];

Future<Uint8List> _solidImage(Size size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0000FF));
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<Uint8List> _capture(WidgetTester tester, GlobalKey key) async {
  return (await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }))!;
}

List<int> _pixel(Uint8List pixels, int x, int y) => pixels.sublist((y * 100 + x) * 4, (y * 100 + x) * 4 + 4);

void main() {
  late Drift db;
  const request = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const cancel = BasicMessageChannel<Object?>(
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
    messenger.setMockDecodedMessageHandler(request, (_) async => <Object?>[null]);
    messenger.setMockDecodedMessageHandler(cancel, (_) async => <Object?>[null]);
  });

  tearDownAll(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(request, null);
    messenger.setMockDecodedMessageHandler(cancel, null);
    await Store.clear();
    await SettingsRepository.reset();
    await db.close();
  });

  test('mosaic cover does not inherit screenshot or separated-face contain fallback', () {
    for (final preserveEdges in [false, true]) {
      final framing = faceAwareThumbnailFraming(
        imageSize: const Size(100, 200),
        viewportSize: const Size.square(100),
        faces: _separatedFaces,
        preserveEdgeContent: preserveEdges,
        allowContain: false,
      );
      expect(framing.fit, BoxFit.cover);
      expect(framing.alignment, Alignment.center);
      final legacy = faceAwareThumbnailFraming(
        imageSize: const Size(100, 200),
        viewportSize: const Size.square(100),
        faces: _separatedFaces,
        preserveEdgeContent: preserveEdges,
      );
      expect(legacy.fit, BoxFit.contain);
    }
  });

  test('mosaic retains safe face alignment when the face fits a cover crop', () {
    final framing = faceAwareThumbnailFraming(
      imageSize: const Size(100, 200),
      viewportSize: const Size.square(100),
      faces: const [Rect.fromLTRB(.3, .02, .6, .2)],
      allowContain: false,
    );
    expect(framing.fit, BoxFit.cover);
    expect(framing.alignment.y, lessThan(0));
    expect(framing.alignment.x, inInclusiveRange(-1, 1));
  });

  test('mosaic decode request covers the viewport rather than using a smaller contain decode', () {
    final cover = buildTimelineThumbnailRequest(
      viewportSize: const Size.square(180),
      devicePixelRatio: 3,
      imageSize: const Size(4000, 6000),
      faces: _separatedFaces,
      preserveEdgeContent: true,
      allowContain: false,
    );
    final contain = buildTimelineThumbnailRequest(
      viewportSize: const Size.square(180),
      devicePixelRatio: 3,
      imageSize: const Size(4000, 6000),
      faces: _separatedFaces,
      preserveEdgeContent: true,
    );
    expect(cover.requiredSize, const Size(540, 810));
    expect(contain.requiredSize, const Size(360, 540));
    expect(cover.decodeSize.longestSide, lessThanOrEqualTo(1440));
    expect(cover.decodeSize.aspectRatio, closeTo(2 / 3, 1e-9));
    expect(cover.remoteMediaSize, AssetMediaSize.preview);
  });

  for (final source in [const Size(100, 200), const Size(200, 100)]) {
    testWidgets('mosaic paints all four cell edges from a real $source image', (tester) async {
      final image = MemoryImage((await tester.runAsync(() => _solidImage(source)))!);
      final captureKey = GlobalKey();
      await tester.pumpConsumerWidgetRaw(
        Center(
          child: RepaintBoundary(
            key: captureKey,
            child: SizedBox.square(
              dimension: 100,
              child: ColoredBox(
                color: const Color(0xFFFF00FF),
                child: Thumbnail(
                  imageProvider: image,
                  preserveEdgeContent: true,
                  faces: _separatedFaces,
                  fillCell: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() => precacheImage(image, tester.element(find.byType(Thumbnail))));
      await tester.pumpAndSettle();
      final pixels = await _capture(tester, captureKey);
      for (final point in [const Offset(2, 50), const Offset(97, 50), const Offset(50, 2), const Offset(50, 97)]) {
        expect(_pixel(pixels, point.dx.toInt(), point.dy.toInt()), [0, 0, 255, 255]);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('legacy edge-preserving thumbnail retains contain while mosaic repaints without reloading', (
    tester,
  ) async {
    final image = MemoryImage((await tester.runAsync(() => _solidImage(const Size(100, 200))))!);
    final fillCell = ValueNotifier(false);
    addTearDown(fillCell.dispose);
    final captureKey = GlobalKey();
    await tester.pumpConsumerWidgetRaw(
      Center(
        child: RepaintBoundary(
          key: captureKey,
          child: SizedBox.square(
            dimension: 100,
            child: ColoredBox(
              color: const Color(0xFFFF00FF),
              child: ValueListenableBuilder<bool>(
                valueListenable: fillCell,
                builder: (_, value, _) => Thumbnail(imageProvider: image, preserveEdgeContent: true, fillCell: value),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => precacheImage(image, tester.element(find.byType(Thumbnail))));
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(Thumbnail));
    expect(_pixel(await _capture(tester, captureKey), 2, 50), [255, 0, 255, 255]);
    fillCell.value = true;
    await tester.pumpAndSettle();
    expect(_pixel(await _capture(tester, captureKey), 2, 50), [0, 0, 255, 255]);
    expect(tester.state(find.byType(Thumbnail)), same(state));
    expect(tester.takeException(), isNull);
  });

  Future<ProviderContainer> mountTile(WidgetTester tester, {bool fillCell = true, bool locked = false}) async {
    final asset = TestUtils.createRemoteAsset(
      id: 'mosaic-screenshot',
      width: 1080,
      height: 2400,
    ).copyWith(name: 'Screenshot_20261102_211900.jpg', livePhotoVideoId: 'motion-component');
    await tester.pumpConsumerWidgetRaw(
      Center(
        child: SizedBox(
          width: 180,
          height: 240,
          child: ThumbnailTile(asset, fillCell: fillCell, lockSelection: locked),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(ThumbnailTile)));
  }

  testWidgets('mosaic screenshot fills its cell with a bounded existing thumbnail request', (tester) async {
    await mountTile(tester);
    final thumbnail = tester.widget<Thumbnail>(find.byType(Thumbnail));
    expect(thumbnail.fillCell, isTrue);
    expect(thumbnail.fit, BoxFit.cover);
    expect(thumbnail.preserveEdgeContent, isFalse);
    final provider = thumbnail.imageProvider! as RemoteImageProvider;
    expect(Uri.parse(provider.url).path, endsWith('/thumbnail'));
    expect(provider.decodeSize!.longestSide, lessThanOrEqualTo(1440));
    expect(provider, isNot(isA<RemoteFullImageProvider>()));
    final motion = tester.widget<TimelineLivePhotoTile>(find.byType(TimelineLivePhotoTile));
    expect(motion.fillCell, thumbnail.fillCell);
    expect(motion.framingImageSize, thumbnail.framingImageSize);
    expect(tester.takeException(), isNull);
  });

  testWidgets('active motion and still use the same filled framing and bounded decode requirement', (tester) async {
    await SettingsRepository.instance.write(SettingsKey.imagePreferRemote, true);
    final directory = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('foto-mosaic-motion-');
      await File('${directory.path}/synthetic.mp4').writeAsBytes([0, 0, 0, 8, 102, 116, 121, 112]);
      return directory;
    }))!;
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/synthetic.mp4');
    final asset = TestUtils.createRemoteAsset(
      id: 'mosaic-motion',
      width: 4000,
      height: 6000,
    ).copyWith(localId: 'device-motion', livePhotoVideoId: 'motion-video', name: 'Screenshot_motion.jpg');
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpConsumerWidgetRaw(
        TimelineLivePhotoScope(
          localVideoResolver: (_) async => file.path,
          child: FaceAwareThumbnailScope(
            child: Center(child: SizedBox.square(dimension: 180, child: ThumbnailTile(asset, fillCell: true))),
          ),
        ),
        overrides: [
          assetServiceProvider.overrideWithValue(MockAssetService()),
          thumbnailFaceBoundsProvider.overrideWith((_, _) => Stream.value(_separatedFaces)),
        ],
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(livePhotoSettlingDelay);
      await tester.pump();
      final fitted = tester.widget<FittedBox>(
        find.ancestor(of: find.byType(NativeVideoViewer), matching: find.byType(FittedBox)),
      );
      final thumbnail = tester.widget<Thumbnail>(find.byType(Thumbnail));
      expect(fitted.fit, BoxFit.cover);
      expect(fitted.alignment, Alignment.center);
      final request = buildTimelineThumbnailRequest(
        viewportSize: tester.getSize(find.byType(Thumbnail)),
        devicePixelRatio: MediaQuery.devicePixelRatioOf(tester.element(find.byType(Thumbnail))),
        imageSize: thumbnail.framingImageSize,
        faces: thumbnail.faces,
        allowContain: false,
      );
      final video = tester.widget<NativeVideoViewer>(find.byType(NativeVideoViewer));
      expect(video.timelinePreviewImageSize, thumbnail.framingImageSize);
      expect(video.timelinePreviewRequiredSize, request.requiredSize);
      expect((thumbnail.imageProvider! as RemoteImageProvider).decodeSize, request.decodeSize);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mosaic selection changes only the overlay, preserving image bounds, state and square inner corners', (
    tester,
  ) async {
    final container = await mountTile(tester);
    final asset = tester.widget<ThumbnailTile>(find.byType(ThumbnailTile)).asset!;
    final before = tester.getRect(find.byType(Hero));
    final thumbnailState = tester.state(find.byType(Thumbnail));
    expect(before, tester.getRect(find.byType(ThumbnailTile)));
    container.read(multiSelectProvider.notifier).selectAsset(asset);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(Hero)), before);
    expect(tester.getRect(find.byType(Thumbnail)), before);
    expect(tester.state(find.byType(Thumbnail)), same(thumbnailState));
    for (final clip in tester.widgetList<ClipRRect>(
      find.descendant(of: find.byType(ThumbnailTile), matching: find.byType(ClipRRect)),
    )) {
      expect(clip.borderRadius, BorderRadius.zero);
    }
    final overlay = find.byWidgetPredicate((widget) => widget is ColoredBox && widget.color.a == 0.25);
    expect(overlay, findsOneWidget);
    final opacity = tester.widget<AnimatedOpacity>(find.ancestor(of: overlay, matching: find.byType(AnimatedOpacity)));
    expect(opacity.opacity, 1);
    final check = tester.getRect(find.byIcon(Icons.check_circle_rounded));
    expect(check.left, closeTo(before.left + 8, 1e-9));
    expect(check.top, closeTo(before.top + 8, 1e-9));
    container.read(multiSelectProvider.notifier).reset();
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(Hero)), before);
    expect(tester.state(find.byType(Thumbnail)), same(thumbnailState));
    expect(tester.takeException(), isNull);
  });

  testWidgets('locked mosaic selection also keeps the complete image geometry', (tester) async {
    await mountTile(tester, locked: true);
    expect(tester.getRect(find.byType(Hero)), tester.getRect(find.byType(ThumbnailTile)));
    expect(tester.getRect(find.byType(Thumbnail)), tester.getRect(find.byType(ThumbnailTile)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy thumbnail selection keeps its existing inset outside the mosaic', (tester) async {
    final container = await mountTile(tester, fillCell: false);
    final tile = tester.widget<ThumbnailTile>(find.byType(ThumbnailTile));
    final before = tester.getRect(find.byType(ThumbnailTile));
    container.read(multiSelectProvider.notifier).selectAsset(tile.asset!);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(Hero)), before.deflate(6));
    expect(tester.widget<Thumbnail>(find.byType(Thumbnail)).preserveEdgeContent, isTrue);
    expect(tester.takeException(), isNull);
  });
}
