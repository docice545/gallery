import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_file_path.provider.dart';
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

class _Readonly extends ReadOnlyModeNotifier {
  @override
  bool build() => true;
}

void main() {
  testWidgets('real photo gestures: only single tap toggles; zoom and pan retain the asset and hidden controls', (
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
    final fixture = await PresentationContext.create();
    addTearDown(fixture.dispose);
    final assets = [LocalAssetFactory.create(id: 'first'), LocalAssetFactory.create(id: 'second')];
    when(() => fixture.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
    final timeline = _Timeline(assets);
    addTearDown(timeline.dispose);
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(initial: true, page: PageInfo('Home', builder: (_) => const SizedBox())),
        AutoRoute(page: PageInfo('ViewerGestures', builder: (_) => const AssetViewer(initialIndex: 0))),
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
              readonlyModeProvider.overrideWith(_Readonly.new),
            ],
            child: Builder(
              builder: (context) => MaterialApp.router(
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
    unawaited(router.push(const PageRouteInfo('ViewerGestures')));
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
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 350));
    await settleGestures();
    expect(state().showingControls, isFalse);

    // Actual double tap through PhotoView's gesture recognizers, not a notifier call.
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 350));
    await settleGestures();
    expect(state().isZoomed, isTrue);
    expect(state().showingControls, isFalse);
    expect(tester.widget<PageView>(find.byType(PageView)).physics, isA<NeverScrollableScrollPhysics>());
    // A second double tap reaches 1:1 originalSize, also larger than contained.
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 350));
    await settleGestures();
    expect(state().isZoomed, isTrue, reason: 'originalSize must also lock PageView');
    expect(state().showingControls, isFalse);
    await tester.dragFrom(center, const Offset(-180, 10));
    await settleGestures();
    expect(state().currentAsset?.id, assets.first.id);
    expect(state().showingControls, isFalse);

    // Returning to contained scale must not show the floating panels either.
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 350));
    await settleGestures();
    expect(state().isZoomed, isFalse);
    expect(state().showingControls, isFalse);
    // Actual two-finger scale gestures cannot request controls either.
    final left = await tester.startGesture(center - const Offset(50, 0), pointer: 11);
    final right = await tester.startGesture(center + const Offset(50, 0), pointer: 12);
    await left.moveTo(center - const Offset(110, 0));
    await right.moveTo(center + const Offset(110, 0));
    await tester.pump();
    await left.up();
    await right.up();
    await settleGestures();
    expect(state().isZoomed, isTrue);
    expect(state().showingControls, isFalse);
    expect(state().currentAsset?.id, assets.first.id);
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 350));
    await settleGestures();
    expect(state().isZoomed, isFalse);
    await tester.dragFrom(center, const Offset(0, 40));
    await settleGestures();
    expect(router.current.name, 'ViewerGestures');
    expect(state().showingControls, isFalse);

    await tester.fling(find.byType(PageView), const Offset(-320, 0), 1000);
    await settleGestures();
    expect(state().currentAsset?.id, assets.last.id);
    expect(state().showingControls, isFalse);
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 350));
    await settleGestures();
    expect(state().showingControls, isTrue);
    expect(find.byType(PhotoView), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
