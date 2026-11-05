import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_file_path.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';
import 'package:immich_mobile/widgets/photo_view/src/core/photo_view_core.dart';
import 'package:mocktail/mocktail.dart';

import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';
import '../../../widget_tester_extensions.dart';

class _Timeline extends TimelineService {
  _Timeline(this.assets)
    : super((
        origin: TimelineOrigin.deepLink,
        assetSource: (index, count) async => assets.skip(index).take(count).toList(),
        bucketSource: () => Stream.value([Bucket(assetCount: assets.length)]),
      ));
  final List<BaseAsset> assets;
  @override
  int get totalAssets => assets.length;
  @override
  BaseAsset? getAssetSafe(int index) => index >= 0 && index < assets.length ? assets[index] : null;
  @override
  Future<BaseAsset?> getAssetAsync(int index) async => getAssetSafe(index);
}

class _Viewer extends AssetViewerStateNotifier {
  _Viewer(this.asset);
  final BaseAsset asset;
  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: asset);
  }
}

class _Path extends ViewIntentFilePathNotifier {
  _Path(this.path);
  final String path;
  @override
  String build() => path;
}

void main() {
  setUpAll(() async {
    await (FontLoader('GoogleSans')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final brightness in Brightness.values) {
    testWidgets('real viewer Lens handoff preserves photo transform, route and controls in $brightness', (
      tester,
    ) async {
      // Hidden details / adjacent native-image placeholders may keep animating.
      // Wait for the finite route/gesture animations, then assert the actual
      // decoded PhotoView surface instead of waiting for unrelated spinners.
      Future<void> settleGestures() async {
        for (var frame = 0; frame < 30; frame++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      final imageFile = await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp('foto-viewer-gestures-');
        addTearDown(() => directory.delete(recursive: true));
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(const Rect.fromLTWH(0, 0, 2400, 1600), Paint()..color = Colors.blue);
        canvas.drawCircle(const Offset(1200, 800), 300, Paint()..color = Colors.amber);
        final picture = recorder.endRecording();
        final image = await picture.toImage(2400, 1600);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        return File('${directory.path}/synthetic.png').writeAsBytes(bytes!.buffer.asUint8List());
      });
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final method in ['requestImage', 'cancelRequest']) {
        final channel = BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.immich_mobile.LocalImageApi.$method',
          LocalImageApi.pigeonChannelCodec,
        );
        messenger.setMockDecodedMessageHandler(channel, (_) async => <Object?>[null]);
        addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
      }
      final fixture = await PresentationContext.create();
      addTearDown(fixture.dispose);
      final assets = [LocalAssetFactory.create(id: 'first'), LocalAssetFactory.create(id: 'second')];
      when(() => fixture.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
      final timeline = _Timeline(assets);
      addTearDown(timeline.dispose);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      Future<void> capture(String phase) async {
        const directory = String.fromEnvironment('FOTO_LENS_CAPTURE');
        if (directory.isEmpty) {
          return;
        }
        final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(directory).create(recursive: true);
          await File(
            '$directory/lens-real-viewer-${brightness.name}-$phase.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      final router = RootStackRouter.build(
        routes: [
          AutoRoute(initial: true, page: PageInfo('Home', builder: (_) => const SizedBox())),
          AutoRoute(page: PageInfo('ViewerLens', builder: (_) => const AssetViewer(initialIndex: 0))),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        router.dispose();
      });
      await tester.pumpWidget(
        localizedForTest(
          ProviderScope(
            overrides: fixture.overrides,
            child: ProviderScope(
              overrides: [
                timelineServiceProvider.overrideWithValue(timeline),
                assetViewerProvider.overrideWith(() => _Viewer(assets.first)),
                viewIntentFilePathProvider.overrideWith(() => _Path(imageFile!.path)),
              ],
              child: Builder(
                builder: (context) => MaterialApp.router(
                  debugShowCheckedModeBanner: false,
                  builder: (_, child) => RepaintBoundary(key: boundary, child: child),
                  theme: ThemeData(brightness: brightness, useMaterial3: true, fontFamily: 'GoogleSans'),
                  locale: context.locale,
                  localizationsDelegates: context.localizationDelegates,
                  supportedLocales: context.supportedLocales,
                  routerConfig: router.config(),
                ),
              ),
            ),
          ),
        ),
      );
      await settleGestures();
      final homeContext = tester.element(find.byType(Navigator).last);
      await tester.runAsync(() => precacheImage(FileImage(imageFile!), homeContext));
      unawaited(router.push(const PageRouteInfo('ViewerLens')));
      await settleGestures();
      final photo = tester.widget<PhotoView>(find.byKey(Key(assets.first.heroTag)).first);
      expect(photo.imageProvider, FileImage(imageFile!));
      await tester.runAsync(() => precacheImage(photo.imageProvider!, tester.element(find.byType(AssetViewer))));
      await settleGestures();
      expect(
        tester
            .widgetList<PhotoViewCore>(find.byType(PhotoViewCore))
            .any((core) => core.scaleBoundaries.childSize == const Size(2400, 1600)),
        isTrue,
        reason: 'gesture acceptance requires the decoded original, not a loading cover',
      );
      final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
      AssetViewerState state() => container.read(assetViewerProvider);
      final center = tester.getCenter(find.byType(PageView));

      expect(state().showingControls, isTrue);
      // A real decoded PhotoView is zoomed and panned before opening tools.
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(center);
      await settleGestures();
      await tester.dragFrom(center, const Offset(35, 12));
      await settleGestures();
      expect(state().isZoomed, isTrue);
      if (!state().showingControls) {
        await tester.tapAt(center);
        await tester.pump(const Duration(milliseconds: 350));
        await settleGestures();
      }
      expect(state().showingControls, isTrue);
      final beforeState = state();
      final core = tester
          .widgetList<PhotoViewCore>(find.byType(PhotoViewCore))
          .firstWhere((core) => core.scaleBoundaries.childSize == const Size(2400, 1600));
      final beforeTransform = core.controller.value;
      final beforeRect = tester.getRect(find.byKey(Key(assets.first.heroTag)).first);
      await capture('before');
      await tester.tap(find.byTooltip('More'));
      await settleGestures();
      expect(find.text('Google Lens'), findsOneWidget);
      await tester.ensureVisible(find.text('Google Lens'));
      await capture('menu');
      await tester.tap(find.text('Google Lens'));
      await settleGestures();
      verifyNever(
        () => fixture.repository.assetMedia.api.shareAssets(
          any(),
          any(),
          fileType: any(named: 'fileType'),
          livePhotoMode: any(named: 'livePhotoMode'),
          cancelCompleter: any(named: 'cancelCompleter'),
          onAssetDownloadProgress: any(named: 'onAssetDownloadProgress'),
        ),
      );
      await capture('dialog');
      await tester.tap(find.widgetWithText(FilledButton, 'Choose an app'));
      await settleGestures();
      verify(
        () => fixture.repository.assetMedia.api.shareAssets(
          [assets.first],
          any(),
          fileType: ShareAssetType.original,
          livePhotoMode: LivePhotoShareMode.imageOnly,
          cancelCompleter: any(named: 'cancelCompleter'),
          onAssetDownloadProgress: any(named: 'onAssetDownloadProgress'),
        ),
      ).called(1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settleGestures();
      expect(router.current.name, 'ViewerLens');
      expect(find.byType(AlertDialog), findsNothing);
      expect(state(), beforeState);
      final afterCore = tester
          .widgetList<PhotoViewCore>(find.byType(PhotoViewCore))
          .firstWhere((item) => item.scaleBoundaries.childSize == const Size(2400, 1600));
      expect(afterCore.controller, same(core.controller));
      expect(afterCore.controller.value, beforeTransform);
      expect(tester.getRect(find.byKey(Key(assets.first.heroTag)).first), beforeRect);
      expect(find.byTooltip('Share'), findsOneWidget);
      await capture('after');
      expect(tester.takeException(), isNull);
    });
  }
}
