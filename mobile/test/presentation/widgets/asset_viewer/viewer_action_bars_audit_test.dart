import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/colors.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/bottom_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_bottom_app_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/ocr.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_file_path.provider.dart';
import 'package:immich_mobile/theme/color_scheme.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';
import 'package:immich_mobile/widgets/photo_view/src/core/photo_view_core.dart';
import 'package:mocktail/mocktail.dart';

import '../../../riverpod_mocks.dart';
import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/factories/remote_asset_factory.dart';
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
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final cloud in [false, true]) {
        testWidgets('real viewer geometry $brightness font=$scale cloud=$cloud', (tester) async {
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
            canvas.drawRect(const Rect.fromLTWH(0, 0, 1200, 2400), Paint()..color = Colors.blue);
            canvas.drawCircle(const Offset(600, 1200), 300, Paint()..color = Colors.amber);
            final picture = recorder.endRecording();
            final image = await picture.toImage(1200, 2400);
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
          final assets = <BaseAsset>[
            if (cloud)
              RemoteAssetFactory.create(
                id: 'first',
                ownerId: fixture.currentUser.id,
              ).copyWith(createdAt: DateTime(2026, 11, 5, 18, 22))
            else
              LocalAssetFactory.create(id: 'first').copyWith(createdAt: DateTime(2026, 11, 5, 18, 22)),
            LocalAssetFactory.create(id: 'second'),
          ];
          when(() => fixture.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
          final timeline = _Timeline(assets);
          addTearDown(timeline.dispose);
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
          tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final boundary = GlobalKey();
          Future<void> capture(String phase) async {
            const directory = String.fromEnvironment('FOTO_AUDIT_CAPTURE');
            if (directory.isEmpty) {
              return;
            }
            final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await render.toImage();
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              await Directory(directory).create(recursive: true);
              await File(
                '$directory/viewer-${brightness.name}-$scale-${cloud ? 'cloud' : 'local'}-$phase.png',
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
                    if (cloud) ocrAssetProvider(assets.first.id).overrideWith((ref) async => []),
                    serverInfoProvider.overrideWith(
                      (ref) => StubServerInfoNotifier(
                        fixture.service.serverInfo,
                        version: const ServerVersion(major: 2, minor: 6, patch: 0),
                      ),
                    ),
                  ],
                  child: Builder(
                    builder: (context) => MaterialApp.router(
                      debugShowCheckedModeBanner: false,
                      builder: (_, child) => RepaintBoundary(key: boundary, child: child),
                      theme: getThemeData(
                        colorScheme: brightness == Brightness.light
                            ? ImmichColorPreset.indigo.themeOfPreset.light
                            : ImmichColorPreset.indigo.themeOfPreset.dark,
                        locale: const Locale('ru'),
                      ),
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
          await tester.element(find.byType(Navigator).last).setLocale(const Locale('ru'));
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
                .any((core) => core.scaleBoundaries.childSize == const Size(1200, 2400)),
            isTrue,
            reason: 'gesture acceptance requires the decoded original, not a loading cover',
          );
          final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
          AssetViewerState state() => container.read(assetViewerProvider);
          final center = tester.getCenter(find.byType(PageView));

          final top = find.byType(ViewerTopAppBar);
          final bottom = find.byType(ViewerBottomBar);
          final topRect = tester.getRect(top);
          final topSurface = find.descendant(of: top, matching: find.byType(ViewerControlSurface));
          final bottomSurface = find.descendant(of: bottom, matching: find.byType(ViewerControlSurface));
          final bottomRect = tester.getRect(bottomSurface);
          final topPaint = find
              .descendant(
                of: topSurface,
                matching: find.byWidgetPredicate(
                  (w) => w is Material && w.type != MaterialType.transparency && w.shape is StadiumBorder,
                ),
              )
              .first;
          final pageRect = tester.getRect(find.byType(PageView));
          final beforeRect = tester.getRect(find.byKey(Key(assets.first.heroTag)).first);
          final core = tester
              .widgetList<PhotoViewCore>(find.byType(PhotoViewCore))
              .firstWhere((c) => c.scaleBoundaries.childSize == const Size(1200, 2400));
          final transform = core.controller.value;
          expect(pageRect, const Rect.fromLTWH(0, 0, 390, 844));
          expect(transform.scale, closeTo(390 / 1200, .0001));
          expect(transform.position, Offset.zero);
          expect(topRect.height, 76, reason: '112 is a loose upper bound, never a reserved toolbar height');
          expect(tester.getSize(topPaint).height, 44);
          expect(tester.getRect(topPaint).top, 28);
          expect(bottomRect.bottom, 820);
          expect(bottomRect.left, 12);
          expect(bottomRect.right, 378);
          expect(topRect.bottom, lessThan(bottomRect.top));
          final actions = find.descendant(of: bottom, matching: find.byType(SelectionToolbarAction));
          for (final element in actions.evaluate()) {
            final button = find.descendant(of: find.byWidget(element.widget), matching: find.byType(TextButton));
            expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
          }
          expect(state().showingControls, isTrue);
          await capture('visible');
          // A point inside the alleged 112dp reservation, but below the actual bar,
          // must reach the real decoded PhotoView and hide both bars.
          final freePoint = Offset(195, topRect.bottom + 8);
          expect(freePoint.dy, lessThan(24 + const ViewerTopAppBar().preferredSize.height));
          await tester.tapAt(freePoint);
          await tester.pump(const Duration(milliseconds: 350));
          await settleGestures();
          expect(state().showingControls, isFalse);
          for (final bar in [top, find.byType(ViewerBottomAppBar)]) {
            final opacity = find.descendant(of: bar, matching: find.byType(AnimatedOpacity)).first;
            expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
          }
          expect(tester.getRect(find.byKey(Key(assets.first.heroTag)).first), beforeRect);
          expect(core.controller.value, transform);
          await capture('hidden');
          // A hidden bar's old hit region must no longer intercept photo taps.
          await tester.tapAt(Offset(195, topRect.center.dy));
          await tester.pump(const Duration(milliseconds: 350));
          await settleGestures();
          expect(state().showingControls, isTrue);
          expect(tester.getRect(find.byKey(Key(assets.first.heroTag)).first), beforeRect);
          expect(core.controller.value, transform);
          // Double-tap and pan remain available between the visible bars.
          await tester.tapAt(center);
          await tester.pump(const Duration(milliseconds: 80));
          await tester.tapAt(center);
          await settleGestures();
          expect(state().isZoomed, isTrue);
          final zoom = core.controller.value.scale;
          expect(zoom, greaterThan(transform.scale!));
          await tester.dragFrom(center, const Offset(30, 12));
          await settleGestures();
          expect(core.controller.value.position, isNot(transform.position));
          expect(core.controller.value.scale, zoom);
          const directory = String.fromEnvironment('FOTO_AUDIT_CAPTURE');
          if (directory.isNotEmpty) {
            await tester.runAsync(
              () =>
                  File('$directory/geometry-${brightness.name}-$scale-${cloud ? 'cloud' : 'local'}.json').writeAsString(
                    jsonEncode({
                      'source': '010a7a667',
                      'viewport': [390, 844],
                      'fontScale': scale,
                      'topPreferred': 112,
                      'topActualIncludingStatus': topRect.height,
                      'topPainted': tester.getSize(topPaint).height,
                      'statusInset': 24,
                      'navigationInset': 24,
                      'bottomPainted': bottomRect.height,
                      'photoViewport': pageRect.toString(),
                      'photoTransformStableOnToggle': true,
                      'gestureBelowTopAndThroughHiddenPanel': true,
                    }),
                  ),
            );
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
