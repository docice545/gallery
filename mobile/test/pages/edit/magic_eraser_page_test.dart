import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/magic_eraser.model.dart';
import 'package:immich_mobile/presentation/pages/edit/magic_eraser.page.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/repositories/magic_eraser.repository.dart';
import 'package:immich_mobile/widgets/common/transparent_image.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' as api;

import '../../test_utils.dart';
import '../../widget_tester_extensions.dart';
import 'editor_theme_test_host.dart';

class _MockMagicEraserRepository extends Mock implements MagicEraserRepository {}

void main() {
  late _MockMagicEraserRepository repository;
  late RemoteAsset asset;
  late Uint8List source;
  late Uint8List result;
  final canvas = find.byKey(const Key('eraser-canvas'));
  final remove = find.byKey(const Key('eraser-remove'));
  final save = find.byKey(const Key('eraser-save'));
  final cancel = find.byKey(const Key('eraser-cancel'));

  setUpAll(() => registerFallbackValue(<MagicEraserStroke>[]));

  setUp(() {
    TestUtils.init();
    repository = _MockMagicEraserRepository();
    asset = TestUtils.createRemoteAsset(id: 'server-only-asset', width: 1, height: 1);
    source = Uint8List.fromList(kTransparentImage);
    result = Uint8List.fromList(kTransparentImage);
    when(() => repository.isEnabled(asset.id, abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => true);
    when(() => repository.source(asset.id, abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => source);
    when(() => repository.cancel(any(), any())).thenAnswer((_) async {});
    when(
      () => repository.preview(any(), any(), abortTrigger: any(named: 'abortTrigger')),
    ).thenAnswer((_) async => result);
  });

  Future<void> pumpEditor(
    WidgetTester tester, {
    RemoteAsset? photo,
    Widget Function(Widget page)? wrap,
    ThemeMode? themeMode,
  }) async {
    await tester.runAsync(() async {
      final page = MagicEraserPage(asset: photo ?? asset);
      final overrides = [
        magicEraserRepositoryProvider.overrideWithValue(repository),
        ...editorThemeTestOverrides(themeMode ?? ThemeMode.dark),
      ];
      await tester.pumpWidget(
        localizedForTest(
          ProviderScope(
            overrides: overrides,
            child: EditorThemeTestApp(child: wrap?.call(page) ?? page),
          ),
        ),
      );
      // Native descriptor/image decoding completes outside the fake timer zone.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  bool canRemove(WidgetTester tester) => tester.widget<FilledButton>(remove).onPressed != null;

  bool canSave(WidgetTester tester) => tester.widget<FilledButton>(save).onPressed != null;

  Future<void> selectCenter(WidgetTester tester) async {
    await tester.tapAt(tester.getCenter(canvas));
    await tester.pump();
    expect(canRemove(tester), isTrue);
  }

  Future<void> disposeEditor(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Future<void> showResult(WidgetTester tester) async {
    when(
      () => repository.create(asset.id, any()),
    ).thenAnswer((_) async => const MagicEraserJob(id: 'ready-job', status: MagicEraserStatus.ready));
    await selectCenter(tester);
    await tester.ensureVisible(remove);
    await tester.runAsync(() async {
      await tester.tap(remove);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(canSave(tester), isTrue);
  }

  MemoryImage displayedImage(WidgetTester tester) =>
      tester.widget<Image>(find.descendant(of: canvas, matching: find.byType(Image))).image as MemoryImage;

  // Keep the tiny fixtures used by the existing service/lifecycle tests. The
  // gesture tests use a decoded, opaque photo with a realistic aspect ratio.
  Future<Uint8List> solidPng(
    WidgetTester tester, {
    int width = 600,
    int height = 1000,
    Color color = Colors.white,
  }) async {
    return (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = color);
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      picture.dispose();
      try {
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        image.dispose();
      }
    }))!;
  }

  Future<void> setSourceSize(WidgetTester tester, {int width = 600, int height = 1000}) async {
    asset = TestUtils.createRemoteAsset(id: asset.id, width: width, height: height);
    source = await solidPng(tester, width: width, height: height);
    result = source;
  }

  Future<void> waitForGestureSource(WidgetTester tester) async {
    for (var attempt = 0; attempt < 100 && canvas.evaluate().isEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(canvas, findsOneWidget);
    await tester.runAsync(() => precacheImage(MemoryImage(source), tester.element(canvas)));
    await tester.pump();
  }

  Future<void> pumpGestureEditor(WidgetTester tester, {int width = 600, int height = 1000}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await setSourceSize(tester, width: width, height: height);
    await pumpEditor(tester);
    await waitForGestureSource(tester);
  }

  Offset imagePoint(WidgetTester tester, Offset normalized) {
    final box = tester.renderObject<RenderBox>(canvas);
    return box.localToGlobal(Offset(normalized.dx * box.size.width, normalized.dy * box.size.height));
  }

  Future<List<int>> pixelAt(WidgetTester tester, Offset global) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.ancestor(of: canvas, matching: find.byType(RepaintBoundary)).first,
    );
    final local = boundary.globalToLocal(global);
    return (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final x = local.dx.floor();
        final y = local.dy.floor();
        expect(x, inInclusiveRange(0, image.width - 1));
        expect(y, inInclusiveRange(0, image.height - 1));
        final offset = (y * image.width + x) * 4;
        return [for (var channel = 0; channel < 4; channel++) data.getUint8(offset + channel)];
      } finally {
        image.dispose();
      }
    }))!;
  }

  void expectPurple(List<int> rgba) {
    // Sample the stroke interior, allowing rounding in alpha compositing.
    expect(rgba[0], greaterThan(210), reason: 'purple mask red channel');
    expect(rgba[1], lessThan(210), reason: 'purple mask green channel');
    expect(rgba[2], greaterThan(235), reason: 'purple mask blue channel');
    expect(rgba[3], 255);
  }

  Future<List<MagicEraserStroke>> submitSelection(WidgetTester tester) async {
    when(
      () => repository.create(asset.id, any()),
    ).thenAnswer((_) async => const MagicEraserJob(id: 'build27-geometry-job', status: MagicEraserStatus.failed));
    expect(canRemove(tester), isTrue);
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pump();
    return verify(() => repository.create(asset.id, captureAny())).captured.single as List<MagicEraserStroke>;
  }

  bool canUndo(WidgetTester tester) =>
      tester.widget<IconButton>(find.byKey(const Key('eraser-header-undo'))).onPressed != null;

  bool canRedo(WidgetTester tester) =>
      tester.widget<IconButton>(find.byKey(const Key('eraser-header-redo'))).onPressed != null;

  Future<void> tapImage(WidgetTester tester, Offset normalized) async {
    await tester.tapAt(imagePoint(tester, normalized));
    await tester.pump();
  }

  Future<void> seedUndoAndRedo(WidgetTester tester) async {
    await tapImage(tester, const Offset(.25, .25));
    await tapImage(tester, const Offset(.75, .25));
    await tester.tap(find.byKey(const Key('eraser-header-undo')));
    await tester.pump();
    expect(canUndo(tester), isTrue);
    expect(canRedo(tester), isTrue);
  }

  Offset letterboxPoint(WidgetTester tester) {
    final image = tester.getRect(canvas);
    final region = tester.getRect(find.byKey(const Key('eraser-canvas-region')));
    if (image.left - region.left > 8) {
      return Offset((region.left + image.left) / 2, image.center.dy);
    }
    if (image.top - region.top > 8) {
      return Offset(image.center.dx, (region.top + image.top) / 2);
    }
    fail('The realistic fixture must leave letterbox space inside the canvas region');
  }

  for (final dimensions in [const Size(600, 1000), const Size(1200, 800)]) {
    testWidgets(
      'Magic Eraser follows live system theme without losing mask, brush options, zoom or history on $dimensions',
      (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        tester.view.physicalSize = const Size(393, 852);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 28, bottom: 24);
        addTearDown(tester.view.reset);
        await setSourceSize(tester, width: dimensions.width.toInt(), height: dimensions.height.toInt());
        await pumpEditor(tester, themeMode: ThemeMode.system);
        await waitForGestureSource(tester);
        await selectCenter(tester);
        final state = tester.state(find.byType(MagicEraserPage));
        final viewport = tester.getRect(find.byKey(const Key('eraser-canvas-region')));
        final controller = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!;
        controller.value = Matrix4.identity()
          ..scaleByDouble(1.5, 1.5, 1, 1)
          ..translateByDouble(-24, -36, 0, 1);
        await tester.pump();
        final transform = controller.value.clone();
        await tester.tap(find.byKey(const Key('eraser-size-options')));
        await tester.pumpAndSettle();
        for (final phone in [Brightness.dark, Brightness.light]) {
          tester.platformDispatcher.platformBrightnessTestValue = phone;
          await tester.pumpAndSettle();
          final dock = find.byKey(const Key('editor-bottom-panel'));
          expect(Theme.of(tester.element(dock)).brightness, phone);
          expect(Theme.of(tester.element(find.byKey(const Key('editor-parameter-popover')))).brightness, phone);
          expect(tester.getSize(dock).height, 80);
          expect(tester.getRect(find.byKey(const Key('eraser-canvas-region'))), viewport);
          expect(tester.state(find.byType(MagicEraserPage)), same(state));
          expect(
            tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController,
            same(controller),
          );
          expect(controller.value, transform);
          expect(displayedImage(tester).bytes, orderedEquals(source));
          expect(canRemove(tester), isTrue);
          expect(tester.widget<FotoIconButton>(find.byKey(const Key('eraser-brush'))).selected, isTrue);
          final bar = tester.widget<AppBar>(find.byType(AppBar));
          expect(
            bar.systemOverlayStyle!.statusBarIconBrightness,
            phone == Brightness.dark ? Brightness.light : Brightness.dark,
          );
        }
        await tester.tapAt(const Offset(1, 1));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('eraser-header-undo')));
        await tester.pump();
        expect(canRemove(tester), isFalse);
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('eraser-header-redo')));
        await tester.pump();
        expect(canRemove(tester), isTrue);
        verify(() => repository.source(asset.id, abortTrigger: any(named: 'abortTrigger'))).called(1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('Build27 pointer down paints immediately before up on $dimensions', (tester) async {
      await pumpGestureEditor(tester, width: dimensions.width.toInt(), height: dimensions.height.toInt());
      final start = imagePoint(tester, const Offset(.4, .5));
      expect(await pixelAt(tester, start), [255, 255, 255, 255]);
      final gesture = await tester.startGesture(start);
      try {
        // Do not advance the tap recognizer's deadline: the first frame must
        // already show the mask while the finger is still down.
        await tester.pump(Duration.zero);
        expectPurple(await pixelAt(tester, start));
        await gesture.moveBy(const Offset(3, 0));
        await tester.pump(Duration.zero);
        expectPurple(await pixelAt(tester, start + const Offset(3, 0)));
        expect(canRemove(tester), isFalse);
      } finally {
        await gesture.up();
        await tester.pump();
      }
      expect(canRemove(tester), isTrue);
    });

    for (final hold in [Duration.zero, const Duration(milliseconds: 150)]) {
      testWidgets('Build27 short 24 dp drag keeps down and end after $hold on $dimensions', (tester) async {
        await pumpGestureEditor(tester, width: dimensions.width.toInt(), height: dimensions.height.toInt());
        final box = tester.renderObject<RenderBox>(canvas);
        const expectedStart = Offset(.35, .5);
        final expectedEnd = Offset(expectedStart.dx + 24 / box.size.width, expectedStart.dy);
        final gesture = await tester.startGesture(imagePoint(tester, expectedStart));
        await tester.pump(hold);
        await gesture.moveTo(imagePoint(tester, expectedEnd));
        await tester.pump(Duration.zero);
        await gesture.up();
        await tester.pump();

        final strokes = await submitSelection(tester);
        expect(strokes, hasLength(1));
        expect(strokes.single.points.length, greaterThanOrEqualTo(2));
        expect(strokes.single.points.first.dx, closeTo(expectedStart.dx, .0001));
        expect(strokes.single.points.first.dy, closeTo(expectedStart.dy, .0001));
        expect(strokes.single.points.last.dx, closeTo(expectedEnd.dx, .0001));
        expect(strokes.single.points.last.dy, closeTo(expectedEnd.dy, .0001));
      });
    }
  }

  testWidgets('Build27 continuous drag paints the entire path and creates one undo entry', (tester) async {
    await pumpGestureEditor(tester);
    final gesture = await tester.startGesture(imagePoint(tester, const Offset(.2, .6)));
    await gesture.moveTo(imagePoint(tester, const Offset(.45, .6)));
    await tester.pump(Duration.zero);
    expectPurple(await pixelAt(tester, imagePoint(tester, const Offset(.325, .6))));
    await gesture.moveTo(imagePoint(tester, const Offset(.7, .6)));
    await tester.pump(Duration.zero);
    expectPurple(await pixelAt(tester, imagePoint(tester, const Offset(.575, .6))));
    expect(canRemove(tester), isFalse);
    await gesture.up();
    await tester.pump();
    expect(canRemove(tester), isTrue);

    await tester.tap(find.byKey(const Key('eraser-header-undo')));
    await tester.pump();
    expect(canRemove(tester), isFalse);
    expect(canUndo(tester), isFalse);
    expect(canRedo(tester), isTrue);
    expect(await pixelAt(tester, imagePoint(tester, const Offset(.45, .6))), [255, 255, 255, 255]);
    await tester.tap(find.byKey(const Key('eraser-header-redo')));
    await tester.pump();
    final strokes = await submitSelection(tester);
    expect(strokes, hasLength(1));
    expect(strokes.single.points.first.dx, closeTo(.2, .0001));
    expect(strokes.single.points.last.dx, closeTo(.7, .0001));
    for (final point in strokes.single.points) {
      expect(point.dy, closeTo(.6, .0001));
    }
  });

  testWidgets('Build27 erase mask paints immediately and undo restores the visible mask', (tester) async {
    await pumpGestureEditor(tester);
    const center = Offset(.5, .5);
    await tapImage(tester, center);
    expectPurple(await pixelAt(tester, imagePoint(tester, center)));
    final erase = find.byKey(const Key('eraser-erase-mask'));
    await tester.ensureVisible(erase);
    await tester.tap(erase);
    await tester.pump();
    final gesture = await tester.startGesture(imagePoint(tester, center));
    try {
      await tester.pump(Duration.zero);
      expect(await pixelAt(tester, imagePoint(tester, center)), [255, 255, 255, 255]);
    } finally {
      await gesture.up();
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('eraser-header-undo')));
    await tester.pump();
    expectPurple(await pixelAt(tester, imagePoint(tester, center)));
    await tester.tap(find.byKey(const Key('eraser-header-redo')));
    await tester.pump();
    expect(await pixelAt(tester, imagePoint(tester, center)), [255, 255, 255, 255]);
    final strokes = await submitSelection(tester);
    expect(strokes, hasLength(2));
    expect(strokes.first.erase, isFalse);
    expect(strokes.last.erase, isTrue);
    expect(strokes.last.points.single.dx, closeTo(.5, .0001));
    expect(strokes.last.points.single.dy, closeTo(.5, .0001));
  });

  testWidgets('Build27 letterbox starts are ignored and excursions keep all mask coordinates in bounds', (
    tester,
  ) async {
    // The compact controls let a portrait photo almost fill this viewport.
    // Use a wide photo to preserve a real letterbox for this boundary test.
    await pumpGestureEditor(tester, width: 1200, height: 800);
    final outside = letterboxPoint(tester);
    final outsidePixel = await pixelAt(tester, outside);
    final ignored = await tester.startGesture(outside);
    await ignored.moveTo(imagePoint(tester, const Offset(.5, .5)));
    await ignored.up();
    await tester.pump();
    expect(canRemove(tester), isFalse);
    expect(canUndo(tester), isFalse);

    final gesture = await tester.startGesture(imagePoint(tester, const Offset(.8, .5)));
    await gesture.moveTo(outside);
    await tester.pump();
    expect(await pixelAt(tester, outside), outsidePixel);
    await gesture.moveTo(imagePoint(tester, const Offset(.9, .5)));
    await gesture.up();
    await tester.pump();
    final strokes = await submitSelection(tester);
    expect(strokes, hasLength(1));
    expect(strokes.single.points.first.dx, closeTo(.8, .0001));
    expect(strokes.single.points.last.dx, closeTo(.9, .0001));
    for (final point in strokes.single.points) {
      expect(point.dx, inInclusiveRange(0, 1));
      expect(point.dy, inInclusiveRange(0, 1));
    }
  });

  testWidgets('Build27 pointer cancel discards the active stroke and preserves undo and redo', (tester) async {
    await pumpGestureEditor(tester);
    await seedUndoAndRedo(tester);
    const end = Offset(.55, .7);
    final gesture = await tester.startGesture(imagePoint(tester, const Offset(.35, .7)));
    await gesture.moveTo(imagePoint(tester, end));
    await tester.pump();
    expectPurple(await pixelAt(tester, imagePoint(tester, end)));
    await gesture.cancel();
    await tester.pump();
    expect(await pixelAt(tester, imagePoint(tester, end)), [255, 255, 255, 255]);
    expect(canUndo(tester), isTrue);
    expect(canRedo(tester), isTrue);
    expectPurple(await pixelAt(tester, imagePoint(tester, const Offset(.25, .25))));
    await tester.tap(find.byKey(const Key('eraser-header-redo')));
    await tester.pump();
    final strokes = await submitSelection(tester);
    expect(strokes, hasLength(2));
    expect(strokes.first.points.single.dx, closeTo(.25, .0001));
    expect(strokes.last.points.single.dx, closeTo(.75, .0001));
  });

  for (final outsideImage in [false, true]) {
    for (final liftFirstPointer in [false, true]) {
      testWidgets('Build27 second pointer ${outsideImage ? 'outside' : 'inside'} image cancels drawing; '
          '${liftFirstPointer ? 'first' : 'second'} pointer lifts first', (tester) async {
        await pumpGestureEditor(tester, width: outsideImage ? 1200 : 600, height: outsideImage ? 800 : 1000);
        await seedUndoAndRedo(tester);
        const activeEnd = Offset(.55, .7);
        final first = await tester.startGesture(imagePoint(tester, const Offset(.35, .7)), pointer: 1);
        await first.moveTo(imagePoint(tester, activeEnd));
        await tester.pump();
        expectPurple(await pixelAt(tester, imagePoint(tester, activeEnd)));
        final second = await tester.startGesture(
          outsideImage ? letterboxPoint(tester) : imagePoint(tester, const Offset(.75, .75)),
          pointer: 2,
        );
        await tester.pump(Duration.zero);
        expect(await pixelAt(tester, imagePoint(tester, activeEnd)), [255, 255, 255, 255]);
        final remaining = liftFirstPointer ? second : first;
        await (liftFirstPointer ? first : second).up();
        // The remaining finger must stay suppressed, even if it moves back
        // onto the photo after the other finger leaves the canvas.
        await remaining.moveTo(imagePoint(tester, const Offset(.65, .65)));
        await tester.pump();
        expect(await pixelAt(tester, imagePoint(tester, const Offset(.65, .65))), [255, 255, 255, 255]);
        await remaining.up();
        await tester.pump();
        expect(canUndo(tester), isTrue);
        expect(canRedo(tester), isTrue);
        expectPurple(await pixelAt(tester, imagePoint(tester, const Offset(.25, .25))));
        await tester.tap(find.byKey(const Key('eraser-header-redo')));
        await tester.pump();
        final strokes = await submitSelection(tester);
        expect(strokes, hasLength(2));
        expect(strokes.first.points.single.dx, closeTo(.25, .0001));
        expect(strokes.last.points.single.dx, closeTo(.75, .0001));
      });
    }
  }

  testWidgets('Build27 real pinch and pan preserve image-local brush coordinates after Zoom', (tester) async {
    await pumpGestureEditor(tester, width: 1200, height: 800);
    final zoom = find.byKey(const Key('eraser-zoom'));
    await tester.ensureVisible(zoom);
    await tester.tap(zoom);
    await tester.pump();
    final center = tester.getCenter(canvas);
    final first = await tester.startGesture(center - const Offset(40, 0), pointer: 1);
    final second = await tester.startGesture(center + const Offset(40, 0), pointer: 2);
    await first.moveTo(center - const Offset(80, 0));
    await second.moveTo(center + const Offset(80, 0));
    await tester.pump();
    await first.moveBy(const Offset(30, 15));
    await second.moveBy(const Offset(30, 15));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    final transform = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!.value;
    expect(transform.getMaxScaleOnAxis(), greaterThan(1.2));
    expect(transform.entry(0, 3).abs() + transform.entry(1, 3).abs(), greaterThan(1));
    expect(canRemove(tester), isFalse);
    expect(canUndo(tester), isFalse);
    final brush = find.byKey(const Key('eraser-brush'));
    await tester.ensureVisible(brush);
    await tester.tap(brush);
    await tester.pump();
    const expected = Offset(.45, .55);
    final global = imagePoint(tester, expected);
    expect(tester.getRect(find.byKey(const Key('eraser-canvas-region'))).contains(global), isTrue);
    await tester.tapAt(global);
    await tester.pump();
    expectPurple(await pixelAt(tester, global));
    final strokes = await submitSelection(tester);
    expect(strokes, hasLength(1));
    expect(strokes.single.points, hasLength(1));
    expect(strokes.single.points.single.dx, closeTo(expected.dx, .0001));
    expect(strokes.single.points.single.dy, closeTo(expected.dy, .0001));
  });

  testWidgets('Build27 original and Live notices are absent in English and Russian', (tester) async {
    const notices = [
      'Works on the original photo without your current edits. Your edits will still be in the editor when you return.',
      'The saved copy is a still photo without the motion component. Your original Live/Motion Photo is preserved.',
      'Обрабатывается исходная фотография без текущих правок. Ваши правки останутся в редакторе после возвращения.',
      'Копия будет обычной фотографией без движения. Исходное Live/Motion Photo сохранится.',
    ];
    for (final locale in ['en', 'ru']) {
      for (final motion in [false, true]) {
        await pumpEditor(tester, photo: motion ? asset.copyWith(livePhotoVideoId: 'linked-video') : asset);
        await EasyLocalization.of(tester.element(canvas))!.setLocale(Locale(locale));
        await tester.pumpAndSettle();
        for (final notice in notices) {
          expect(find.text(notice), findsNothing, reason: 'locale=$locale motion=$motion');
        }
        await disposeEditor(tester);
      }
    }
  });

  testWidgets('Build27 real drag previews and saves a separate copy then pops without changing the original pair', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await setSourceSize(tester);
    asset = asset.copyWith(livePhotoVideoId: 'build27-linked-video', stackId: 'build27-original-stack');
    final original = asset;
    final assetSnapshot = asset.copyWith();
    final sourceObject = source;
    final sourceSnapshot = Uint8List.fromList(source);
    result = await solidPng(tester, color: Colors.green);
    expect(result, isNot(equals(source)));
    final saved = Completer<String>();
    when(
      () => repository.create(original.id, any()),
    ).thenAnswer((_) async => const MagicEraserJob(id: 'build27-ready-job', status: MagicEraserStatus.ready));
    when(() => repository.save(original.id, 'build27-ready-job')).thenAnswer((_) => saved.future);
    String? routeResult;
    await pumpEditor(
      tester,
      photo: original,
      wrap: (page) => Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              key: const Key('build27-open-editor'),
              onPressed: () async {
                routeResult = await Navigator.of(context).push<String>(MaterialPageRoute<String>(builder: (_) => page));
              },
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('build27-open-editor')));
    await tester.pump();
    await waitForGestureSource(tester);
    await tester.pumpAndSettle();
    expect(displayedImage(tester).bytes, same(sourceObject));
    const start = Offset(.2, .6);
    const end = Offset(.65, .6);
    final gesture = await tester.startGesture(imagePoint(tester, start));
    await gesture.moveTo(imagePoint(tester, const Offset(.4, .6)));
    await tester.pump(Duration.zero);
    await gesture.moveTo(imagePoint(tester, end));
    await gesture.up();
    await tester.pump();
    expect(canRemove(tester), isTrue);
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pump();
    final strokes =
        verify(() => repository.create(original.id, captureAny())).captured.single as List<MagicEraserStroke>;
    expect(strokes, hasLength(1));
    expect(strokes.single.points.first.dx, closeTo(start.dx, .0001));
    expect(strokes.single.points.last.dx, closeTo(end.dx, .0001));
    for (var attempt = 0; attempt < 100 && !canSave(tester); attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(canSave(tester), isTrue);
    expect(displayedImage(tester).bytes, same(result));
    expect(displayedImage(tester).bytes, isNot(equals(sourceSnapshot)));
    await tester.runAsync(() => precacheImage(MemoryImage(result), tester.element(canvas)));
    await tester.pump();
    expect(await pixelAt(tester, imagePoint(tester, const Offset(.5, .5))), [76, 175, 80, 255]);
    verify(
      () => repository.preview(original.id, 'build27-ready-job', abortTrigger: any(named: 'abortTrigger')),
    ).called(1);
    verifyNever(() => repository.save(any(), any()));
    await tester.tap(save);
    await tester.pump();
    expect(canSave(tester), isFalse);
    expect(routeResult, isNull);
    saved.complete('build27-new-copy-id');
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(MagicEraserPage), findsNothing);
    expect(find.byKey(const Key('build27-open-editor')), findsOneWidget);
    expect(routeResult, 'build27-new-copy-id');
    verify(() => repository.save(original.id, 'build27-ready-job')).called(1);
    verifyNever(() => repository.cancel(original.id, 'build27-ready-job'));
    verifyNever(() => repository.create('build27-linked-video', any()));
    verifyNever(() => repository.save('build27-linked-video', any()));
    expect(source, same(sourceObject));
    expect(source, orderedEquals(sourceSnapshot));
    expect(original, assetSnapshot);
    expect(original.id, isNot('build27-new-copy-id'));
    expect(original.localId, isNull);
    expect(original.isEdited, isFalse);
    expect(original.livePhotoVideoId, 'build27-linked-video');
    expect(original.stackId, 'build27-original-stack');
    // Let the existing success toast finish its bounded dismissal timer.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final (screen, textScale) in <(Size, double)>[
    (const Size(390, 844), 1),
    (const Size(320, 568), 1),
    (const Size(568, 320), 1),
    (const Size(844, 390), 1),
    (const Size(800, 1280), 1),
    (const Size(390, 844), 2),
    (const Size(320, 568), 2),
    (const Size(568, 320), 2),
    (const Size(844, 390), 2),
    (const Size(800, 1280), 2),
  ]) {
    for (final photo in [const Size(600, 1000), const Size(1200, 800)]) {
      testWidgets(
        'Build28 content-sized panel keeps an uncropped $photo photo and usable controls at $screen/$textScale',
        (tester) async {
          tester.view.physicalSize = screen;
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
          tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
          tester.platformDispatcher.textScaleFactorTestValue = textScale;
          addTearDown(() {
            tester.view.reset();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
          });
          await setSourceSize(tester, width: photo.width.toInt(), height: photo.height.toInt());
          await pumpEditor(tester);
          await waitForGestureSource(tester);
          await EasyLocalization.of(tester.element(canvas))!.setLocale(const Locale('ru'));
          await tester.pumpAndSettle();

          final region = tester.getRect(find.byKey(const Key('eraser-canvas-region')));
          final panel = find.byKey(const Key('eraser-controls-panel'));
          final panelRect = tester.getRect(panel);
          final image = tester.getRect(canvas);
          final fitted = applyBoxFit(BoxFit.contain, photo, region.size).destination;
          expect(image.width, closeTo(fitted.width, .001));
          expect(image.height, closeTo(fitted.height, .001));
          expect(image.width / image.height, closeTo(photo.width / photo.height, .00001));
          expect(image.center.dx, closeTo(region.center.dx, .001));
          expect(image.center.dy, closeTo(region.center.dy, .001));
          expect(image.left, greaterThanOrEqualTo(region.left - .001));
          expect(image.top, greaterThanOrEqualTo(region.top - .001));
          expect(image.right, lessThanOrEqualTo(region.right + .001));
          expect(image.bottom, lessThanOrEqualTo(region.bottom + .001));
          expect(image.width, greaterThan(80));
          expect(image.height, greaterThan(80));

          expect(panelRect.top, closeTo(region.bottom, .001));
          expect(panelRect.height, 80); // One 56 dp row plus the 24 dp system inset.
          expect(panelRect.width, region.width);
          final before = region;
          await tester.ensureVisible(find.byKey(const Key('eraser-size-options')));
          await tester.tap(find.byKey(const Key('eraser-size-options')));
          await tester.pumpAndSettle();
          expect(tester.getRect(find.byKey(const Key('eraser-canvas-region'))), before);
          expect(tester.getRect(panel), panelRect);
          await tester.tapAt(const Offset(1, 1));
          await tester.pumpAndSettle();

          for (final target in [
            find.byKey(const Key('eraser-brush')),
            find.byKey(const Key('eraser-erase-mask')),
            find.byKey(const Key('eraser-zoom')),
            find.byKey(const Key('eraser-reset')),
            find.byKey(const Key('eraser-size-options')),
            remove,
          ]) {
            await tester.ensureVisible(target);
            await tester.pump();
            expect(target.hitTestable(), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          verifyNever(() => repository.create(any(), any()));
          verifyNever(() => repository.save(any(), any()));
        },
      );
    }
  }

  testWidgets('Build28 oversized failure status scrolls while preserving the photo and mask', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await setSourceSize(tester);
    await pumpEditor(tester);
    await waitForGestureSource(tester);
    await EasyLocalization.of(tester.element(canvas))!.setLocale(const Locale('ru'));
    await tester.pumpAndSettle();
    await tapImage(tester, const Offset(.5, .5));
    when(
      () => repository.create(asset.id, any()),
    ).thenAnswer((_) async => const MagicEraserJob(id: 'build28-failed-job', status: MagicEraserStatus.failed));
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pump();
    expect(displayedImage(tester).bytes, same(source));
    expect(canRemove(tester), isTrue);
    expect(tester.getSize(find.byKey(const Key('eraser-canvas-region'))).height, greaterThan(100));
    // Failure status overlays the existing viewport and never adds a dock row.
    final statusText = find.byKey(const Key('eraser-failure-status'));
    expect(statusText, findsOneWidget);
    expect(
      tester.widget<Text>(statusText).style!.color,
      Theme.of(tester.element(statusText)).colorScheme.onErrorContainer,
    );
    await tester.ensureVisible(find.byKey(const Key('eraser-size-options')));
    await tester.tap(find.byKey(const Key('eraser-size-options')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('eraser-brush-size')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a disabled AI service stays unavailable without requesting an original', (tester) async {
    when(() => repository.isEnabled(asset.id, abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => false);

    await pumpEditor(tester);

    expect(canvas, findsNothing);
    expect(remove, findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('The AI eraser service is unavailable. Please try again later.'), findsOneWidget);
    verifyNever(() => repository.source(any(), abortTrigger: any(named: 'abortTrigger')));
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final (error, message) in <(Object, String)>[
      (api.ApiException(401, 'Private response'), 'Sign in again to check magic eraser availability.'),
      (api.ApiException(403, 'Private response'), 'You do not have permission to edit this photo.'),
      (api.ApiException(400, 'Private response'), 'Magic eraser does not support this photo.'),
      (api.ApiException(404, 'Private response'), 'This photo is unavailable, offline or in Trash.'),
      (
        http.ClientException('Private URL'),
        'Could not check magic eraser availability. Check your connection and retry.',
      ),
      (http.RequestAbortedException(), 'Could not check magic eraser availability. Check your connection and retry.'),
      (
        const FormatException('Private payload'),
        'Could not check magic eraser availability. Check your connection and retry.',
      ),
      (
        const MagicEraserCapabilityException(MagicEraserCapabilityFailure.unsupportedBackend),
        'This server does not provide the magic eraser API.',
      ),
      (
        const MagicEraserCapabilityException(MagicEraserCapabilityFailure.unavailablePhoto),
        'This photo is unavailable, offline or in Trash.',
      ),
      (api.ApiException(503, 'Private details'), 'The AI eraser service is unavailable. Please try again later.'),
      (
        api.ApiException(500, 'Private details'),
        'Could not check magic eraser availability. Check your connection and retry.',
      ),
    ]) {
      testWidgets('AI page keeps the availability reason on $platform: $message', (tester) async {
        when(() => repository.isEnabled(asset.id, abortTrigger: any(named: 'abortTrigger'))).thenThrow(error);
        await pumpEditor(tester);
        expect(find.text(message), findsOneWidget);
        expect(find.textContaining('Private'), findsNothing);
        expect(find.text('Retry'), findsOneWidget);
        expect(canvas, findsNothing);
        verifyNever(() => repository.source(any(), abortTrigger: any(named: 'abortTrigger')));
        verifyNever(() => repository.create(any(), any()));
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));
    }
  }

  testWidgets('AI service failure after a successful capability check is not a photo eligibility failure', (
    tester,
  ) async {
    when(
      () => repository.source(asset.id, abortTrigger: any(named: 'abortTrigger')),
    ).thenThrow(api.ApiException(503, 'Private details'));
    await pumpEditor(tester);
    expect(find.text('The AI eraser service is unavailable. Please try again later.'), findsOneWidget);
    expect(canvas, findsNothing);
    verifyNever(() => repository.create(any(), any()));
  });

  testWidgets('an unavailable capability can be checked again without creating or saving a photo', (tester) async {
    when(
      () => repository.isEnabled(asset.id, abortTrigger: any(named: 'abortTrigger')),
    ).thenThrow(http.ClientException('Private URL'));
    await pumpEditor(tester);
    expect(find.text('Could not check magic eraser availability. Check your connection and retry.'), findsOneWidget);
    expect(canSave(tester), isFalse);
    verifyNever(() => repository.source(any(), abortTrigger: any(named: 'abortTrigger')));

    when(() => repository.isEnabled(asset.id, abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => true);
    await tester.runAsync(() async {
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(canvas, findsOneWidget);
    expect(canRemove(tester), isFalse);
    expect(canSave(tester), isFalse);
    verify(() => repository.source(asset.id, abortTrigger: any(named: 'abortTrigger'))).called(1);
    verifyNever(() => repository.create(any(), any()));
    verifyNever(() => repository.save(any(), any()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a server-only source displays without inpainting or importing an asset automatically', (tester) async {
    await pumpEditor(tester);

    expect(canvas, findsOneWidget);
    expect(displayedImage(tester).bytes, same(source));
    expect(canRemove(tester), isFalse);
    expect(canSave(tester), isFalse);
    expect(find.byKey(const Key('eraser-brush-size')), findsNothing);
    expect(find.byKey(const Key('eraser-size-options')), findsOneWidget);
    expect(find.byKey(const Key('eraser-header-undo')), findsOneWidget);
    expect(find.byKey(const Key('eraser-header-redo')), findsOneWidget);
    verifyNever(() => repository.create(any(), any()));
    verifyNever(() => repository.save(any(), any()));
  });

  testWidgets('a failed source download can be retried without creating a job or changing the asset', (tester) async {
    when(() => repository.source(asset.id, abortTrigger: any(named: 'abortTrigger'))).thenThrow(StateError('Offline'));
    await pumpEditor(tester);
    expect(canvas, findsNothing);
    expect(find.text('Retry'), findsOneWidget);

    when(() => repository.source(asset.id, abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => source);
    await tester.runAsync(() async {
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(canvas, findsOneWidget);
    expect(displayedImage(tester).bytes, same(source));
    expect(canRemove(tester), isFalse);
    verifyNever(() => repository.create(any(), any()));
  });

  testWidgets('brush taps, undo, redo and reset maintain a removable selection', (tester) async {
    await pumpEditor(tester);
    await selectCenter(tester);

    await tester.tap(find.byKey(const Key('eraser-header-undo')));
    await tester.pump();
    expect(canRemove(tester), isFalse);
    await tester.tap(find.byKey(const Key('eraser-header-redo')));
    await tester.pump();
    expect(canRemove(tester), isTrue);
    await tester.tap(find.byKey(const Key('eraser-reset')));
    await tester.pump();
    expect(canRemove(tester), isFalse);
    final redoButton = tester.widget<IconButton>(find.byKey(const Key('eraser-header-redo')));
    expect(redoButton.onPressed, isNull);
  });

  testWidgets('a continuous brush drag produces a selection after competing tap gestures cancel', (tester) async {
    when(
      () => repository.create(asset.id, any()),
    ).thenAnswer((_) async => const MagicEraserJob(id: 'drag-job', status: MagicEraserStatus.ready));
    await pumpEditor(tester);
    final imageRect = tester.getRect(canvas);
    final gesture = await tester.startGesture(Offset(imageRect.left + imageRect.width * 0.25, imageRect.center.dy));
    for (var index = 0; index < 4; index++) {
      await gesture.moveBy(Offset(imageRect.width * 0.1, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    expect(canRemove(tester), isTrue);
    await tester.tap(remove);
    await tester.pump();
    await tester.pump();

    final strokes = verify(() => repository.create(asset.id, captureAny())).captured.single as List<MagicEraserStroke>;
    expect(strokes, hasLength(1));
    expect(strokes.single.points.length, greaterThan(1));
    expect(strokes.single.points.last.dx, greaterThan(strokes.single.points.first.dx));
  });

  testWidgets('brush size and additive/eraser gestures are sent as normalized mask operations', (tester) async {
    when(
      () => repository.create(asset.id, any()),
    ).thenAnswer((_) async => const MagicEraserJob(id: 'ready-job', status: MagicEraserStatus.ready));
    await pumpEditor(tester);
    await selectCenter(tester);
    await tester.ensureVisible(find.byKey(const Key('eraser-size-options')));
    await tester.tap(find.byKey(const Key('eraser-size-options')));
    await tester.pumpAndSettle();
    final slider = find.byKey(const Key('eraser-brush-size'));
    final sliderRect = tester.getRect(slider);
    await tester.tapAt(Offset(sliderRect.right - 24, sliderRect.center.dy));
    await tester.pump();
    await tester.tap(find.byKey(const Key('eraser-erase-mask')));
    await tester.tapAt(tester.getCenter(canvas) + const Offset(20, 0));
    await tester.pump();
    await tester.tap(remove);
    await tester.pump();
    await tester.pump();

    final strokes = verify(() => repository.create(asset.id, captureAny())).captured.single as List<MagicEraserStroke>;
    expect(strokes, hasLength(2));
    expect(strokes.first.erase, isFalse);
    expect(strokes.last.erase, isTrue);
    expect(strokes.last.radius, greaterThan(strokes.first.radius));
    for (final stroke in strokes) {
      expect(stroke.radius, inInclusiveRange(0.001, 0.25));
      for (final point in stroke.points) {
        expect(point.dx, inInclusiveRange(0, 1));
        expect(point.dy, inInclusiveRange(0, 1));
      }
    }
    verifyNever(() => repository.save(any(), any()));
  });

  testWidgets('zoom mode enables image gestures and does not paint a selection', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.byKey(const Key('eraser-zoom')));
    await tester.pump();
    final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(viewer.panEnabled, isTrue);
    expect(viewer.scaleEnabled, isTrue);
    await tester.drag(canvas, const Offset(40, 20));
    await tester.pump();
    expect(canRemove(tester), isFalse);
    await tester.tap(find.byKey(const Key('eraser-brush')));
    await tester.pump();
    expect(tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).scaleEnabled, isFalse);
    await selectCenter(tester);
  });

  testWidgets('processing shows progress, prevents repeated submit and stops the known server job on Cancel', (
    tester,
  ) async {
    when(
      () => repository.create(asset.id, any()),
    ).thenAnswer((_) async => const MagicEraserJob(id: 'queued-job', status: MagicEraserStatus.queued));
    await pumpEditor(tester);
    await selectCenter(tester);
    await tester.tap(remove);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(cancel, findsOneWidget);
    expect(canRemove(tester), isFalse);
    expect(tester.widget<FotoIconButton>(find.byKey(const Key('eraser-size-options'))).onPressed, isNull);
    await tester.tap(cancel);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(canRemove(tester), isTrue);
    verify(() => repository.create(asset.id, any())).called(1);
    verify(() => repository.cancel(asset.id, 'queued-job')).called(1);
    verifyNever(() => repository.getJob(any(), any(), abortTrigger: any(named: 'abortTrigger')));
    verifyNever(() => repository.save(any(), any()));
    await disposeEditor(tester);
    verifyNever(() => repository.cancel(asset.id, 'queued-job'));
  });

  testWidgets('Cancel during job creation discards a late result instead of leaving an unknown server job', (
    tester,
  ) async {
    final created = Completer<MagicEraserJob>();
    when(() => repository.create(asset.id, any())).thenAnswer((_) => created.future);
    await pumpEditor(tester);
    await selectCenter(tester);
    await tester.tap(remove);
    await tester.pump();
    await tester.tap(cancel);
    await tester.pump();
    created.complete(const MagicEraserJob(id: 'late-job', status: MagicEraserStatus.ready));
    await tester.pump();

    verify(() => repository.cancel(asset.id, 'late-job')).called(1);
    verifyNever(() => repository.preview(any(), any(), abortTrigger: any(named: 'abortTrigger')));
    expect(canSave(tester), isFalse);
    expect(canRemove(tester), isTrue);
  });

  testWidgets('Before/After changes only the displayed preview and Save copy remains explicit', (tester) async {
    await pumpEditor(tester);
    await showResult(tester);

    expect(displayedImage(tester).bytes, same(result));
    await tester.tap(find.byKey(const Key('eraser-before')));
    await tester.pump();
    expect(displayedImage(tester).bytes, same(source));
    await tester.tap(find.byKey(const Key('eraser-after')));
    await tester.pump();
    expect(displayedImage(tester).bytes, same(result));
    verifyNever(() => repository.save(any(), any()));
    expect(asset.localId, isNull);
    expect(asset.isEdited, isFalse);
    await disposeEditor(tester);
    verify(() => repository.cancel(asset.id, 'ready-job')).called(1);
  });

  testWidgets('Save copy cannot be submitted twice and disposal does not cancel an atomic import', (tester) async {
    final saved = Completer<String>();
    when(() => repository.save(asset.id, 'ready-job')).thenAnswer((_) => saved.future);
    await pumpEditor(tester);
    await showResult(tester);
    await tester.tap(save);
    await tester.pump();

    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(cancel, findsNothing);
    await disposeEditor(tester);
    saved.complete('new-copy-id');
    await tester.pump();

    verify(() => repository.save(asset.id, 'ready-job')).called(1);
    verifyNever(() => repository.cancel(asset.id, 'ready-job'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed processing job retains the original and permits retry without a silent save', (tester) async {
    when(() => repository.create(asset.id, any())).thenAnswer(
      (_) async =>
          const MagicEraserJob(id: 'failed-job', status: MagicEraserStatus.failed, errorCode: 'inpainting_failed'),
    );
    await pumpEditor(tester);
    await selectCenter(tester);
    await tester.tap(remove);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(displayedImage(tester).bytes, same(source));
    expect(canRemove(tester), isTrue);
    expect(canSave(tester), isFalse);
    verifyNever(() => repository.save(any(), any()));
  });

  for (final oversized in [false, true]) {
    testWidgets('rejects an ${oversized ? 'oversized decoded' : 'invalid encoded'} result without offering Save copy', (
      tester,
    ) async {
      Uint8List bytes;
      if (oversized) {
        bytes = (await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final painting = Canvas(recorder);
          painting.drawRect(const Rect.fromLTWH(0, 0, 1601, 1), Paint()..color = Colors.white);
          final picture = recorder.endRecording();
          final image = await picture.toImage(1601, 1);
          picture.dispose();
          try {
            return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
          } finally {
            image.dispose();
          }
        }))!;
      } else {
        bytes = Uint8List.fromList([0, 1, 2, 3]);
      }
      when(
        () => repository.create(asset.id, any()),
      ).thenAnswer((_) async => const MagicEraserJob(id: 'invalid-preview-job', status: MagicEraserStatus.ready));
      when(
        () => repository.preview(any(), any(), abortTrigger: any(named: 'abortTrigger')),
      ).thenAnswer((_) async => bytes);
      await pumpEditor(tester);
      await selectCenter(tester);
      await tester.runAsync(() async {
        await tester.tap(remove);
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(canSave(tester), isFalse);
      expect(displayedImage(tester).bytes, same(source));
      expect(canRemove(tester), isTrue);
      verifyNever(() => repository.save(any(), any()));
      await disposeEditor(tester);
      verify(() => repository.cancel(asset.id, 'invalid-preview-job')).called(1);
    });
  }

  testWidgets('closing while creating a job cancels its late response and does not update a disposed widget', (
    tester,
  ) async {
    final created = Completer<MagicEraserJob>();
    when(() => repository.create(asset.id, any())).thenAnswer((_) => created.future);
    await pumpEditor(tester);
    await selectCenter(tester);
    await tester.tap(remove);
    await tester.pump();
    await disposeEditor(tester);
    created.complete(const MagicEraserJob(id: 'disconnected-job', status: MagicEraserStatus.ready));
    await tester.pump();

    verify(() => repository.cancel(asset.id, 'disconnected-job')).called(1);
    verifyNever(() => repository.preview(any(), any(), abortTrigger: any(named: 'abortTrigger')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Motion/Live Photo editing identifies the independent still copy without changing its pair', (
    tester,
  ) async {
    final live = asset.copyWith(livePhotoVideoId: 'linked-video', stackId: 'existing-stack');
    await pumpEditor(tester, photo: live);

    expect(canvas, findsOneWidget);
    expect(live.livePhotoVideoId, 'linked-video');
    expect(live.stackId, 'existing-stack');
    expect(live.isEdited, isFalse);
    verifyNever(() => repository.save(any(), any()));
  });

  testWidgets('Russian mask controls and Before/After/Save fit a 320 dp viewport with enlarged text', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpEditor(tester, photo: asset.copyWith(livePhotoVideoId: 'motion-video'));
    await EasyLocalization.of(tester.element(canvas))!.setLocale(const Locale('ru'));
    await tester.pumpAndSettle();
    await showResult(tester);
    await tester.pump();

    expect(save, findsOneWidget);
    expect(tester.getRect(save).left, greaterThanOrEqualTo(0));
    expect(tester.getRect(save).right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 720), const Size(720, 320), const Size(568, 320)]) {
    testWidgets('Russian AI editor keeps its canvas and four header actions at font scale 2 on $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final padding = size.width > size.height
          ? const FakeViewPadding(left: 24, right: 24, bottom: 24)
          : const FakeViewPadding(top: 28, bottom: 24);
      tester.view.padding = padding;
      tester.view.viewPadding = padding;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.reset();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      await pumpEditor(tester);
      await EasyLocalization.of(tester.element(canvas))!.setLocale(const Locale('ru'));
      await tester.pumpAndSettle();

      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.actions, hasLength(3));
      for (final key in ['eraser-back', 'eraser-header-undo', 'eraser-header-redo', 'eraser-save']) {
        expectTapTargetMin(tester, find.byKey(Key(key)));
        final rect = tester.getRect(find.byKey(Key(key)));
        expect(rect.left, greaterThanOrEqualTo(padding.left));
        expect(rect.right, lessThanOrEqualTo(size.width - padding.right));
      }
      expect(canSave(tester), isFalse);
      expect(Theme.of(tester.element(canvas)).brightness, Brightness.dark);
      final canvasRegion = tester.getRect(find.byKey(const Key('eraser-canvas-region')));
      final panel = tester.getRect(find.byKey(const Key('eraser-controls-panel')));
      expect(canvasRegion.height, greaterThanOrEqualTo(96));
      expect(canvasRegion.width, greaterThanOrEqualTo(96));
      expect(panel.top, closeTo(canvasRegion.bottom, .001));
      expect(panel.height, 56 + padding.bottom);
      await tester.ensureVisible(remove);
      expect(remove.hitTestable(), findsOneWidget);
      await showResult(tester);
      expect(canSave(tester), isTrue);
      await tester.ensureVisible(find.byKey(const Key('eraser-before')));
      await tester.tap(find.byKey(const Key('eraser-before')));
      await tester.pump();
      expect(displayedImage(tester).bytes, same(source));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('keyboard and cutout insets preserve the AI mask and scrollable controls', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 28, bottom: 24);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await pumpEditor(tester);
    await selectCenter(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    tester.view.padding = const FakeViewPadding(top: 28);
    await tester.pumpAndSettle();

    expect(canRemove(tester), isTrue);
    expect(tester.getSize(find.byKey(const Key('eraser-canvas-region'))).height, greaterThan(96));
    await tester.ensureVisible(remove);
    expect(remove.hitTestable(), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('eraser-controls-panel'))).bottom, lessThanOrEqualTo(440));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('eraser-header-undo')));
    await tester.pump();
    expect(canRemove(tester), isFalse);
  });
}
