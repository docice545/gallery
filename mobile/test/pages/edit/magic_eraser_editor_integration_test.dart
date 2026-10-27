import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crop_image/crop_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/magic_eraser.model.dart';
import 'package:immich_mobile/presentation/pages/edit/annotation_canvas.dart';
import 'package:immich_mobile/presentation/pages/edit/edit.page.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/pages/edit/magic_eraser.page.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/repositories/magic_eraser.repository.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';
import 'package:immich_mobile/widgets/common/transparent_image.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' as api;

import '../../fixtures/editor_raster.dart';
import '../../test_utils.dart';
import '../../widget_tester_extensions.dart';

class _MockMagicEraserRepository extends Mock implements MagicEraserRepository {}

void main() {
  late _MockMagicEraserRepository repository;
  late RemoteAsset asset;
  final magicEraser = find.byType(MagicEraserPage);

  setUpAll(() => registerFallbackValue(<MagicEraserStroke>[]));

  setUp(() {
    TestUtils.init();
    repository = _MockMagicEraserRepository();
    asset = TestUtils.createRemoteAsset(id: 'asset-id', width: 1, height: 1);
    when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => false);
    when(
      () => repository.source(any(), abortTrigger: any(named: 'abortTrigger')),
    ).thenAnswer((_) async => Uint8List.fromList(kTransparentImage));
    when(() => repository.cancel(any(), any())).thenAnswer((_) async {});
  });

  Future<void> pumpEditor(WidgetTester tester, {RemoteAsset? photo, bool legacyCaller = false, Image? image}) async {
    await tester.runAsync(() async {
      await tester.pumpConsumerWidgetRaw(
        EditImagePage(
          image: image ?? Image.memory(kTransparentImage),
          applyEdits: (_) async {},
          asset: legacyCaller ? null : photo ?? asset,
        ),
        overrides: [
          magicEraserRepositoryProvider.overrideWithValue(repository),
          immichThemeProvider.overrideWith(
            (ref) => ImmichTheme(
              light: ColorScheme.fromSeed(seedColor: Colors.purple),
              dark: ColorScheme.fromSeed(seedColor: Colors.purple, brightness: Brightness.dark),
            ),
          ),
        ],
      );
    });
    await tester.pump();
    // Native decoding must complete before the crop surface mounts. A single
    // fixed sleep flakes when codegen/analyzer/test workers compete for CPU.
    if (legacyCaller || (photo ?? asset).isEditable) {
      for (var attempt = 0; attempt < 100 && find.byType(CropImage).evaluate().isEmpty; attempt++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(find.byType(CropImage), findsOneWidget, reason: 'The editable preview must finish decoding');
      await tester.tap(find.byKey(const Key('editor-mode-crop')));
      await tester.pumpAndSettle();
    }
  }

  Future<void> selectMode(WidgetTester tester, String mode) async {
    if (mode == 'filters' || mode == 'stickers') {
      final more = find.byKey(const Key('editor-more'));
      if (more.evaluate().isEmpty) {
        final crop = find.byKey(const Key('editor-mode-crop'));
        await tester.ensureVisible(crop);
        await tester.tap(crop);
        await tester.pumpAndSettle();
        if (more.evaluate().isEmpty) {
          await tester.tap(crop);
          await tester.pumpAndSettle();
        }
      }
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
    }
    final target = find.byKey(Key('editor-mode-$mode'));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pump();
    if (mode == 'magicEraser') {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('the only save command offers a copy without unavailable replacement controls', (tester) async {
    await pumpEditor(tester);
    final save = find.byKey(const Key('editor-save'));
    expect(tester.widget<TextButton>(save).onPressed, isNull);
    expect(find.text('Save\na copy'), findsOneWidget);
    expect(find.byKey(const Key('edit-save-mode-dialog')), findsNothing);
    expect(find.byKey(const Key('edit-replace-original')), findsNothing);
    await tester.tap(find.byIcon(Icons.rotate_left));
    await tester.pump();
    expect(tester.widget<TextButton>(save).onPressed, isNotNull);
  });

  testWidgets('fourth tool opens the existing AI page directly with a reason and retry', (tester) async {
    await pumpEditor(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
    container.read(editorStateProvider.notifier).rotateCCW();
    final before = container.read(editorStateProvider);
    await selectMode(tester, 'magicEraser');
    expect(magicEraser, findsOneWidget);
    expect(find.text('The AI eraser service is unavailable. Please try again later.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    verifyNever(() => repository.source(any(), abortTrigger: any(named: 'abortTrigger')));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    verify(() => repository.isEnabled(asset.id, abortTrigger: any(named: 'abortTrigger'))).called(2);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(container.read(editorStateProvider), before);
    expect(find.byKey(const Key('editor-mode-crop')), findsOneWidget);
  });

  testWidgets('double activation before the next frame opens only one AI route and capability request', (tester) async {
    await pumpEditor(tester);
    final button = tester.widget<TextButton>(find.byKey(const Key('editor-mode-magicEraser')));
    button.onPressed!();
    button.onPressed!();
    await tester.pumpAndSettle();
    expect(find.byType(MagicEraserPage, skipOffstage: false), findsOneWidget);
    verify(() => repository.isEnabled(asset.id, abortTrigger: any(named: 'abortTrigger'))).called(1);
    await tester.pageBack();
    await tester.pumpAndSettle();
    button.onPressed!();
    await tester.pumpAndSettle();
    expect(find.byType(MagicEraserPage, skipOffstage: false), findsOneWidget);
    verify(() => repository.isEnabled(asset.id, abortTrigger: any(named: 'abortTrigger'))).called(1);
  });

  testWidgets('local-only editor explains AI availability without uploading a source or changing edits', (
    tester,
  ) async {
    await pumpEditor(tester, legacyCaller: true);
    final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
    container.read(editorStateProvider.notifier).rotateCCW();
    final before = container.read(editorStateProvider);
    await selectMode(tester, 'magicEraser');
    expect(
      find.text('Magic Eraser needs a photo saved on the server. Your edits stay in this editor.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('magic-eraser-local-retry')), findsOneWidget);
    verifyNever(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger')));
    verifyNever(() => repository.source(any(), abortTrigger: any(named: 'abortTrigger')));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(container.read(editorStateProvider), before);
  });

  for (final saveResult in [false, true]) {
    testWidgets('AI ${saveResult ? 'saved copy' : 'cancel'} preserves the parent draft and complete undo/redo history', (
      tester,
    ) async {
      when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => true);
      when(
        () => repository.create(asset.id, any()),
      ).thenAnswer((_) async => const MagicEraserJob(id: 'ready-job', status: MagicEraserStatus.ready));
      when(
        () => repository.preview(any(), any(), abortTrigger: any(named: 'abortTrigger')),
      ).thenAnswer((_) async => Uint8List.fromList(kTransparentImage));
      when(() => repository.save(asset.id, 'ready-job')).thenAnswer((_) async => 'separate-ai-copy');
      await pumpEditor(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
      final notifier = container.read(editorStateProvider.notifier);
      notifier.setCrop(const Rect.fromLTWH(.1, .1, .8, .8));
      notifier.rotateCW();
      notifier.setStraightenDegrees(7);
      notifier.setAnnotations([
        AnnotationElement(
          id: 'retained-markup',
          tool: AnnotationTool.pen,
          points: const [Offset(.4, .4)],
          color: Colors.blue,
          width: 5,
          opacity: 1,
        ),
      ]);
      notifier.undo();
      final before = container.read(editorStateProvider);
      expect(before.canRedo, isTrue);
      await selectMode(tester, 'magicEraser');
      expect(magicEraser, findsOneWidget);
      expect(
        find.text(
          'Works on the original photo without your current edits. Your edits will still be in the editor when you return.',
        ),
        findsOneWidget,
      );
      if (saveResult) {
        final canvas = find.byKey(const Key('eraser-canvas'));
        for (var i = 0; i < 100 && canvas.evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
        await tester.tapAt(tester.getCenter(canvas));
        await tester.pump();
        final remove = find.byKey(const Key('eraser-remove'));
        await tester.ensureVisible(remove);
        await tester.runAsync(() async {
          await tester.tap(remove);
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        await tester.tap(find.byKey(const Key('eraser-save')));
        await tester.pumpAndSettle();
        verify(() => repository.save(asset.id, 'ready-job')).called(1);
        verifyNever(() => repository.cancel(asset.id, 'ready-job'));
      } else {
        await tester.pageBack();
        await tester.pumpAndSettle();
        verifyNever(() => repository.save(any(), any()));
      }
      expect(magicEraser, findsNothing);
      expect(container.read(editorStateProvider), before);
      notifier.redo();
      expect(container.read(editorStateProvider).annotations.single.id, 'retained-markup');
      notifier.undo();
      expect(container.read(editorStateProvider), before);
      notifier.undo();
      expect(container.read(editorStateProvider).straightenDegrees, 0);
      expect(container.read(editorStateProvider).rotationAngle, 90);
      expect(container.read(editorStateProvider).crop, before.crop);
      if (saveResult) {
        // The existing success notification has a bounded dismissal timer.
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets('Live/Motion stills expose the fourth AI tool without enabling transform or overwrite', (tester) async {
    final live = asset.copyWith(livePhotoVideoId: 'paired-video-id');
    await pumpEditor(tester, photo: live);
    expect(tester.widget<TextButton>(find.byKey(const Key('editor-mode-crop'))).onPressed, isNull);
    expect(tester.widget<TextButton>(find.byKey(const Key('editor-save'))).onPressed, isNull);
    expect(find.byType(CropImage), findsNothing);
    await selectMode(tester, 'magicEraser');
    expect(magicEraser, findsOneWidget);
    expect(live.livePhotoVideoId, 'paired-video-id');
  });

  testWidgets(
    'frame and straighten retain crop angle and history; transformed drawing maps back to source after resize',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final source = (await tester.runAsync(createEditorRaster))!;
      addTearDown(source.dispose);
      final png = (await tester.runAsync(() => EditedImageExporter.encodePng(source)))!;
      await pumpEditor(tester, image: Image.memory(png));
      final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
      final notifier = container.read(editorStateProvider.notifier);
      notifier.setCrop(const Rect.fromLTRB(.125, .125, .875, .875));
      notifier.rotateCW();
      notifier.flipHorizontally();
      notifier.setStraightenDegrees(8);
      await tester.pumpAndSettle();
      final before = container.read(editorStateProvider);
      final straighten = find.byKey(const Key('editor-crop-straighten'));
      await tester.ensureVisible(straighten);
      await tester.tap(straighten);
      await tester.pumpAndSettle();
      expect(container.read(editorStateProvider), before);
      expect(tester.widget<CropImage>(find.byType(CropImage)).showCorners, isFalse);
      final slider = tester.widget<Slider>(find.byKey(const Key('editor-straighten-slider')));
      slider.onChangeStart!(8);
      slider.onChanged!(10);
      slider.onChanged!(12);
      slider.onChangeEnd!(12);
      await tester.pump();
      notifier.undo();
      expect(container.read(editorStateProvider).straightenDegrees, 8);
      notifier.redo();
      expect(container.read(editorStateProvider).straightenDegrees, 12);
      await tester.ensureVisible(find.byKey(const Key('editor-crop-frame')));
      await tester.tap(find.byKey(const Key('editor-crop-frame')));
      await tester.pumpAndSettle();
      expect(tester.widget<CropImage>(find.byType(CropImage)).showCorners, isTrue);
      expect(container.read(editorStateProvider).crop, before.crop);
      expect(container.read(editorStateProvider).straightenDegrees, 12);
      await selectMode(tester, 'draw');
      final canvas = find.byType(AnnotationCanvas);
      var box = tester.renderObject<RenderBox>(canvas);
      var start = box.localToGlobal(Offset(box.size.width * .45, box.size.height * .45));
      var end = box.localToGlobal(Offset(box.size.width * .55, box.size.height * .5));
      await tester.dragFrom(start, end - start);
      await tester.pump();
      final editor = tester.widget<AnnotationCanvas>(canvas).editor;
      expect(editor.elements, hasLength(1));
      expect(editor.elements.single.points.first.dx, closeTo(.45, .002));
      expect(editor.elements.single.points.first.dy, closeTo(.45, .002));
      expect(editor.elements.single.points.last.dx, closeTo(.55, .002));
      expect(editor.elements.single.points.last.dy, closeTo(.5, .002));
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      box = tester.renderObject<RenderBox>(canvas);
      start = box.localToGlobal(Offset(box.size.width * .5, box.size.height * .55));
      end = box.localToGlobal(Offset(box.size.width * .6, box.size.height * .5));
      await tester.dragFrom(start, end - start);
      await tester.pump();
      expect(editor.elements, hasLength(2));
      expect(editor.elements.last.points.first.dx, closeTo(.5, .002));
      expect(editor.elements.last.points.first.dy, closeTo(.55, .002));
      expect(editor.elements.last.points.last.dx, closeTo(.6, .002));
      expect(container.read(editorStateProvider).crop, before.crop);
      expect(container.read(editorStateProvider).straightenDegrees, 12);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('preview and active settings stay between the panels at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpEditor(tester);
      final panel = find.byKey(const Key('editor-bottom-panel'));
      final canvas = find.byType(AnnotationCanvas);
      expect(tester.getRect(canvas).top, greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom));
      if (size.width > size.height) {
        expect(tester.getRect(canvas).right, lessThanOrEqualTo(tester.getRect(panel).left));
      } else {
        expect(tester.getRect(canvas).bottom, lessThanOrEqualTo(tester.getRect(panel).top));
      }
      expect(find.byKey(const Key('editor-markup-controls')), findsNothing);
      expect(magicEraser, findsNothing);
      expect(find.byKey(const Key('annotation-toggle')), findsNothing);

      await tester.ensureVisible(find.byKey(const Key('editor-mode-draw')));
      await tester.tap(find.byKey(const Key('editor-mode-draw')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editor-markup-controls')), findsOneWidget);
      expect(find.byIcon(Icons.rotate_left), findsNothing);
      expect(magicEraser, findsNothing);
      if (size.width > size.height) {
        expect(tester.getRect(canvas).right, lessThanOrEqualTo(tester.getRect(panel).left));
      } else {
        expect(tester.getRect(canvas).bottom, lessThanOrEqualTo(tester.getRect(panel).top));
      }
      final viewport = tester.getRect(find.byKey(const Key('editor-preview-viewport')));
      final fitted = applyBoxFit(BoxFit.contain, const Size(1, 1), viewport.size).destination;
      expect(tester.getSize(canvas), fitted);
      expect(tester.getCenter(canvas), viewport.center);
      expect(tester.takeException(), isNull);
    });
  }

  for (final locale in ['en', 'ru']) {
    for (final size in [const Size(320, 720), const Size(720, 320), const Size(844, 390)]) {
      for (final scale in [1.3, 2.0]) {
        testWidgets('$locale tools stay usable at $size and text scale $scale', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await pumpEditor(tester);
          final page = find.byType(EditImagePage);
          await EasyLocalization.of(tester.element(page))!.setLocale(Locale(locale));
          await tester.pumpAndSettle();

          const modes = ['crop', 'filters', 'draw', 'stickers', 'text'];
          for (var index = 0; index < modes.length; index++) {
            final mode = modes[index];
            await selectMode(tester, mode);
            if (mode != 'filters' && mode != 'stickers') {
              expect(tester.getSize(find.byKey(Key('editor-mode-$mode'))).shortestSide, greaterThanOrEqualTo(48));
            }
            final viewport = tester.getRect(find.byKey(const Key('editor-preview-viewport')));
            final appBar = tester.getRect(find.byType(AppBar));
            final panel = tester.getRect(find.byKey(const Key('editor-bottom-panel')));
            final bar = tester.getRect(find.byKey(const Key('editor-mode-bar')));
            expect(viewport.top, closeTo(appBar.bottom, .01));
            if (size.width > size.height) {
              expect(viewport.right, closeTo(panel.left, .01));
              expect(viewport.height, greaterThanOrEqualTo(size.height - appBar.bottom - .01));
            } else {
              expect(viewport.bottom, closeTo(panel.top, .01));
              expect(viewport.height, greaterThanOrEqualTo((size.height - appBar.bottom) * .6));
            }
            expect(panel.bottom, closeTo(size.height, .01));
            expect(bar.bottom, closeTo(panel.bottom, .01));
            expect(bar.height, lessThanOrEqualTo(100));
            final markup = mode == 'draw' || mode == 'text' || mode == 'stickers';
            expect(find.byKey(const Key('editor-markup-controls')), markup ? findsOneWidget : findsNothing);
            expect(magicEraser, findsNothing);
            if (markup) {
              if (mode == 'draw') {
                await tester.tap(find.byKey(const Key('editor-toggle-settings')));
                await tester.pumpAndSettle();
              }
              final slider = find.byKey(Key(mode == 'draw' ? 'annotation-width' : 'annotation-opacity'));
              await tester.ensureVisible(slider);
              await tester.pumpAndSettle();
              final sliderRect = tester.getRect(slider);
              final currentPanel = tester.getRect(find.byKey(const Key('editor-bottom-panel')));
              final currentBar = tester.getRect(find.byKey(const Key('editor-mode-bar')));
              expect(sliderRect.top, greaterThanOrEqualTo(currentPanel.top));
              expect(sliderRect.bottom, lessThanOrEqualTo(currentBar.top));
              await tester.tapAt(sliderRect.center);
              await tester.pumpAndSettle();
              final surface = tester.widget<AnnotationCanvas>(find.byType(AnnotationCanvas));
              expect(mode == 'draw' ? surface.width : surface.opacity, isNot(mode == 'draw' ? 5 : 1));
            }
            expect(tester.takeException(), isNull, reason: 'mode=$mode');
          }
        });
      }
    }
  }

  Rect screenRect(WidgetTester tester, Finder finder) {
    final box = tester.renderObject<RenderBox>(finder);
    return MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
  }

  Future<Uint8List> imageBytes(WidgetTester tester, Size size) async {
    return (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(Offset.zero & size, Paint()..color = Colors.blue);
      final picture = recorder.endRecording();
      final image = await picture.toImage(size.width.toInt(), size.height.toInt());
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    }))!;
  }

  testWidgets('all display rotations and flips keep actual preview pixels and exported markup aligned', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = (await tester.runAsync(createEditorRaster))!;
    addTearDown(source.dispose);
    final png = (await tester.runAsync(() => EditedImageExporter.encodePng(source)))!;
    await pumpEditor(tester, image: Image.memory(png));
    await tester.ensureVisible(find.byKey(const Key('editor-mode-draw')));
    await tester.tap(find.byKey(const Key('editor-mode-draw')));
    await tester.pumpAndSettle();
    final canvas = find.byType(AnnotationCanvas);
    final container = ProviderScope.containerOf(tester.element(canvas));
    final notifier = container.read(editorStateProvider.notifier);
    const marker = Color(0xFF123456);
    tester
        .widget<AnnotationCanvas>(canvas)
        .editor
        .add(
          AnnotationElement(
            id: 'export-marker',
            tool: AnnotationTool.pen,
            points: const [Offset(.625, .5)],
            color: marker,
            width: 60,
            opacity: 1,
          ),
        );
    final annotationCanvas = tester.widget<AnnotationCanvas>(canvas);
    annotationCanvas.onChanged?.call(annotationCanvas.editor.elements);
    await tester.pumpAndSettle();

    final markerElements = tester.widget<AnnotationCanvas>(canvas).editor.elements;
    for (var turn = 0; turn < 4; turn++) {
      for (final horizontal in [false, true]) {
        for (final vertical in [false, true]) {
          notifier.clear();
          notifier.setAnnotations(markerElements);
          for (var count = 0; count < turn; count++) {
            notifier.rotateCW();
          }
          if (horizontal) {
            notifier.flipHorizontally();
          }
          if (vertical) {
            notifier.flipVertically();
          }
          await tester.pumpAndSettle();
          var expected = rotateEditorTiles([
            editorRasterColors[0],
            [Colors.white, Colors.black, marker, const Color(0xFFFF00FF)],
            editorRasterColors[2],
          ], turn);
          // The public controls flip in display coordinates, even when sideways.
          if (horizontal) {
            expected = [for (final row in expected) row.reversed.toList()];
          }
          if (vertical) {
            expected = expected.reversed.toList();
          }
          final argb = [
            for (final row in expected) [for (final color in row) color.toARGB32()],
          ];
          final state = container.read(editorStateProvider);
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.ancestor(of: canvas, matching: find.byType(RepaintBoundary)).first,
          );
          final samples = (await tester.runAsync(() async {
            final preview = await boundary.toImage();
            final output = await EditedImageExporter.render(
              source: source,
              crop: state.crop,
              rotationDegrees: state.rotationAngle,
              straightenDegrees: state.straightenDegrees,
              flipHorizontal: state.flipHorizontal,
              flipVertical: state.flipVertical,
              annotations: tester.widget<AnnotationCanvas>(canvas).editor.elements,
            );
            try {
              return (
                preview: await sampleEditorTiles(preview, columns: expected.first.length, rows: expected.length),
                output: await sampleEditorTiles(output, columns: expected.first.length, rows: expected.length),
                dimensions: (output.width, output.height),
              );
            } finally {
              preview.dispose();
              output.dispose();
            }
          }))!;
          final reason = 'turn=$turn displayHorizontal=$horizontal displayVertical=$vertical';
          expect(samples.preview, argb, reason: 'preview $reason');
          expect(samples.output, argb, reason: 'export $reason');
          expect(samples.dimensions, turn.isOdd ? (48, 64) : (64, 48));
        }
      }
    }
    expect(tester.takeException(), isNull);
  });

  for (final screen in [const Size(390, 844), const Size(844, 390)]) {
    for (final source in [const Size(400, 100), const Size(100, 400)]) {
      testWidgets('decoded $source photo fills available $screen area at every quarter-turn', (tester) async {
        tester.view.physicalSize = screen;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await pumpEditor(tester, image: Image.memory(await imageBytes(tester, source)));
        for (var turn = 0; turn < 5; turn++) {
          final viewport = tester.getRect(find.byKey(const Key('editor-preview-viewport')));
          final canvas = screenRect(tester, find.byType(AnnotationCanvas));
          final painter = find.byWidgetPredicate(
            (widget) => widget is CustomPaint && widget.painter.runtimeType.toString() == '_RotatedImagePainter',
          );
          final photo = screenRect(tester, painter);
          final rotatedSource = turn.isOdd ? Size(source.height, source.width) : source;
          final expected = applyBoxFit(BoxFit.contain, rotatedSource, viewport.size).destination;
          expect(photo.width, closeTo(expected.width, .001));
          expect(photo.height, closeTo(expected.height, .001));
          expect(photo.center.dx, closeTo(viewport.center.dx, .001));
          expect(photo.center.dy, closeTo(viewport.center.dy, .001));
          expect(canvas.left, closeTo(photo.left, .001));
          expect(canvas.top, closeTo(photo.top, .001));
          expect(canvas.right, closeTo(photo.right, .001));
          expect(canvas.bottom, closeTo(photo.bottom, .001));
          expect(photo.top, greaterThanOrEqualTo(viewport.top - .001));
          expect(photo.bottom, lessThanOrEqualTo(viewport.bottom + .001));
          expect(tester.takeException(), isNull);
          if (turn < 4) {
            await tester.tap(find.byIcon(Icons.rotate_right));
            await tester.pumpAndSettle();
          }
        }
      });
    }
  }

  testWidgets('markup ignores letterbox, keeps crop fixed, and stays image-relative after rotation and resize', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpEditor(tester, image: Image.memory(await imageBytes(tester, const Size(400, 100))));
    await tester.tap(find.byIcon(Icons.rotate_left));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('editor-mode-draw')));
    await tester.tap(find.byKey(const Key('editor-mode-draw')));
    await tester.pumpAndSettle();
    final canvas = find.byType(AnnotationCanvas);
    final container = ProviderScope.containerOf(tester.element(canvas));
    final cropBefore = container.read(editorStateProvider).crop;
    final cropWidget = tester.widget<CropImage>(find.byType(CropImage));
    expect(cropWidget.showCorners, isFalse);
    expect(cropWidget.gridColor, Colors.transparent);
    expect(cropWidget.scrimColor, Colors.transparent);
    final viewport = tester.getRect(find.byKey(const Key('editor-preview-viewport')));
    await tester.dragFrom(Offset(viewport.left + 2, viewport.top + 2), const Offset(0, 30));
    await tester.pump();
    final editor = tester.widget<AnnotationCanvas>(canvas).editor;
    expect(editor.elements, isEmpty);

    // Draw at known image coordinates through the quarter-turn's hit-test transform.
    var box = tester.renderObject<RenderBox>(canvas);
    await tester.dragFrom(
      box.localToGlobal(Offset(box.size.width * .2, box.size.height * .3)),
      box.localToGlobal(Offset(box.size.width * .7, box.size.height * .6)) -
          box.localToGlobal(Offset(box.size.width * .2, box.size.height * .3)),
    );
    await tester.pump();
    expect(editor.elements, hasLength(1));
    final points = editor.elements.single.points;
    expect(points.first.dx, closeTo(.2, .001));
    expect(points.first.dy, closeTo(.3, .001));
    expect(points.last.dx, closeTo(.7, .001));
    expect(points.last.dy, closeTo(.6, .001));
    expect(container.read(editorStateProvider).crop, cropBefore);

    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    box = tester.renderObject<RenderBox>(canvas);
    expect(editor.elements.single.points, points);
    expect(box.size.width / box.size.height, closeTo(4, .001));
    final photo = screenRect(tester, canvas);
    final resizedViewport = tester.getRect(find.byKey(const Key('editor-preview-viewport')));
    expect(photo.center.dx, closeTo(resizedViewport.center.dx, .001));
    expect(photo.center.dy, closeTo(resizedViewport.center.dy, .001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing modes keeps annotations and their undo history', (tester) async {
    await pumpEditor(tester);
    await tester.ensureVisible(find.byKey(const Key('editor-mode-draw')));
    await tester.tap(find.byKey(const Key('editor-mode-draw')));
    await tester.pumpAndSettle();
    final canvas = find.byType(AnnotationCanvas);
    await tester.drag(canvas, const Offset(60, 30));
    await tester.pump();
    final editor = tester.widget<AnnotationCanvas>(canvas).editor;
    expect(editor.elements, hasLength(1));
    final original = editor.elements.single;

    await tester.ensureVisible(find.byKey(const Key('editor-mode-text')));
    await tester.tap(find.byKey(const Key('editor-mode-text')));
    await tester.pumpAndSettle();
    await selectMode(tester, 'stickers');
    expect(tester.widget<AnnotationCanvas>(canvas).editor, same(editor));
    expect(editor.elements.single, original);
    await tester.tap(find.byKey(const Key('editor-header-undo')));
    await tester.pump();
    expect(editor.elements, isEmpty);
    await tester.tap(find.byKey(const Key('editor-header-redo')));
    await tester.pump();
    expect(editor.elements.single, original);
  });

  Future<void> pinchAndPan(WidgetTester tester, Offset center) async {
    final first = await tester.startGesture(center - const Offset(40, 0), pointer: 1);
    final second = await tester.startGesture(center + const Offset(40, 0), pointer: 2);
    await first.moveTo(center - const Offset(80, 0));
    await second.moveTo(center + const Offset(80, 0));
    await tester.pump();
    await first.moveBy(const Offset(30, 0));
    await second.moveBy(const Offset(30, 0));
    await tester.pump();
    await first.up();
    // The last remaining finger must not resume drawing or move the crop.
    await second.moveBy(const Offset(10, 0));
    await second.up();
    await tester.pump();
  }

  Offset annotationPoint(WidgetTester tester, Offset point) {
    final box = tester.renderObject<RenderBox>(find.byType(AnnotationCanvas));
    return box.localToGlobal(Offset(point.dx * box.size.width, point.dy * box.size.height));
  }

  Future<AnnotationElement> addTextAnnotation(WidgetTester tester) async {
    await pumpEditor(tester);
    await tester.ensureVisible(find.byKey(const Key('editor-mode-text')));
    await tester.tap(find.byKey(const Key('editor-mode-text')));
    await tester.pumpAndSettle();
    await tester.tapAt(annotationPoint(tester, const Offset(.4, .4)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('annotation-text-input')), 'Original');
    await tester.tap(find.byKey(const Key('annotation-text-confirm')));
    await tester.pumpAndSettle();
    return tester.widget<AnnotationCanvas>(find.byType(AnnotationCanvas)).editor.elements.single;
  }

  testWidgets('editing existing text preserves style and position and creates one undoable edit', (tester) async {
    final original = await addTextAnnotation(tester);
    final editor = tester.widget<AnnotationCanvas>(find.byType(AnnotationCanvas)).editor;
    await tester.tapAt(annotationPoint(tester, original.points.first + const Offset(.01, .01)));
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, original.text);
    expect(find.byKey(const Key('annotation-text-dialog')), findsOneWidget);
    expect(tester.widget<EditableText>(find.byType(EditableText)).maxLines, 4);
    await tester.enterText(find.byKey(const Key('annotation-text-input')), 'First line\nSecond line');
    await tester.tap(find.byKey(const Key('annotation-text-confirm')));
    await tester.pumpAndSettle();
    final edited = original.copyWith(text: 'First line\nSecond line');
    expect(editor.elements.single, edited);

    await tester.tap(find.byKey(const Key('editor-header-undo')));
    await tester.pump();
    expect(editor.elements.single, original);
    await tester.tap(find.byKey(const Key('editor-header-redo')));
    await tester.pump();
    expect(editor.elements.single, edited);
    await tester.tap(find.byKey(const Key('editor-header-undo')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('editor-header-undo')));
    await tester.pump();
    expect(editor.elements, isEmpty);
    final container = ProviderScope.containerOf(tester.element(find.byType(AnnotationCanvas)));
    expect(container.read(editorStateProvider).hasUnsavedEdits, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final outcome in ['cancel', 'empty', 'unchanged']) {
    testWidgets('$outcome text editing preserves the document and undo history', (tester) async {
      final original = await addTextAnnotation(tester);
      final editor = tester.widget<AnnotationCanvas>(find.byType(AnnotationCanvas)).editor;
      await tester.tapAt(annotationPoint(tester, original.points.first + const Offset(.01, .01)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('annotation-text-input')),
        outcome == 'cancel'
            ? 'Discard this draft'
            : outcome == 'empty'
            ? '   '
            : '  Original  ',
      );
      await tester.tap(find.byKey(Key('annotation-text-${outcome == 'cancel' ? 'cancel' : 'confirm'}')));
      await tester.pumpAndSettle();
      expect(editor.elements.single, original);
      await tester.tap(find.byKey(const Key('editor-header-undo')));
      await tester.pump();
      expect(editor.elements, isEmpty);
      expect(editor.canUndo, isFalse);
      await tester.tap(find.byKey(const Key('editor-header-redo')));
      await tester.pump();
      expect(editor.elements.single, original);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('move tool edits selected text after zoom rotation and reflection without moving its anchor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final original = await addTextAnnotation(tester);
    final canvas = find.byType(AnnotationCanvas);
    final container = ProviderScope.containerOf(tester.element(canvas));
    final editor = tester.widget<AnnotationCanvas>(canvas).editor;
    container.read(editorStateProvider.notifier).rotateCCW();
    container.read(editorStateProvider.notifier).flipHorizontally();
    await tester.pumpAndSettle();
    await pinchAndPan(tester, screenRect(tester, canvas).center);
    expect(
      tester.widget<Transform>(find.byKey(const Key('editor-zoom-transform'))).transform.getMaxScaleOnAxis(),
      greaterThan(1),
    );
    expect(find.byKey(const Key('annotation-text-dialog')), findsNothing);
    expect(editor.elements.single, original);

    await tester.tap(find.byType(DropdownButton<AnnotationTool>));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.open_with).last);
    await tester.pumpAndSettle();
    await tester.tapAt(annotationPoint(tester, original.points.first + const Offset(.01, .01)));
    await tester.pump();
    await tester.tap(find.byKey(const Key('annotation-edit-text')));
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, original.text);
    await tester.enterText(find.byKey(const Key('annotation-text-input')), 'After zoom\nStill anchored');
    await tester.tap(find.byKey(const Key('annotation-text-confirm')));
    await tester.pumpAndSettle();
    expect(editor.elements.single, original.copyWith(text: 'After zoom\nStill anchored'));
    expect(container.read(editorStateProvider).rotationAngle, -90);
    expect(container.read(editorStateProvider).flipVertical, isTrue);
    await tester.tap(find.byKey(const Key('editor-header-undo')));
    await tester.pump();
    expect(editor.elements.single, original);
    await tester.tap(find.byKey(const Key('editor-header-redo')));
    await tester.pump();
    expect(editor.elements.single.text, 'After zoom\nStill anchored');
    expect(tester.takeException(), isNull);
  });

  testWidgets('undo and redo keep annotation dirty state aligned with the current document', (tester) async {
    await pumpEditor(tester);
    await tester.ensureVisible(find.byKey(const Key('editor-mode-draw')));
    await tester.tap(find.byKey(const Key('editor-mode-draw')));
    await tester.pumpAndSettle();
    final canvas = find.byType(AnnotationCanvas);
    final editor = tester.widget<AnnotationCanvas>(canvas).editor;
    final container = ProviderScope.containerOf(tester.element(canvas));

    await tester.drag(canvas, const Offset(60, 30));
    await tester.pump();
    expect(editor.elements, hasLength(1));
    expect(container.read(editorStateProvider).hasUnsavedEdits, isTrue);

    await tester.tap(find.byKey(const Key('editor-header-undo')));
    await tester.pump();
    expect(editor.elements, isEmpty);
    expect(container.read(editorStateProvider).hasUnsavedEdits, isFalse);

    await tester.tap(find.byKey(const Key('editor-header-redo')));
    await tester.pump();
    expect(editor.elements, hasLength(1));
    expect(container.read(editorStateProvider).hasUnsavedEdits, isTrue);
  });

  testWidgets('reset restores server edit baseline and clears markup as one undoable document change', (tester) async {
    await pumpEditor(tester);
    final cropMode = find.byKey(const Key('editor-mode-crop'));
    final container = ProviderScope.containerOf(tester.element(cropMode));
    container.read(editorStateProvider.notifier).init([
      CropEdit(api.CropParameters(x: 10, y: 5, width: 60, height: 40)),
      RotateEdit(api.RotateParameters(angle: 90)),
    ], const ExifInfo(width: 100, height: 80));
    await tester.pumpAndSettle();
    final baseline = container.read(editorStateProvider);
    expect(baseline.crop, const Rect.fromLTRB(.1, .0625, .7, .5625));
    expect(baseline.rotationAngle, 90);
    expect(baseline.hasUnsavedEdits, isFalse);

    container.read(editorStateProvider.notifier).setCrop(const Rect.fromLTRB(.15, .1, .8, .75));
    container.read(editorStateProvider.notifier).rotateCW();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('editor-mode-draw')));
    await tester.tap(find.byKey(const Key('editor-mode-draw')));
    await tester.pumpAndSettle();
    final canvas = find.byType(AnnotationCanvas);
    final editor = tester.widget<AnnotationCanvas>(canvas).editor;
    await tester.drag(canvas, const Offset(60, 30));
    await tester.pump();
    expect(editor.elements, hasLength(1));
    expect(container.read(editorStateProvider).hasUnsavedEdits, isTrue);

    await tester.ensureVisible(cropMode);
    await tester.tap(cropMode);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('editor-more')));
    await tester.tap(find.byKey(const Key('editor-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editor-reset')));
    await tester.pumpAndSettle();
    expect(container.read(editorStateProvider).crop, baseline.crop);
    expect(container.read(editorStateProvider).rotationAngle, baseline.rotationAngle);
    expect(container.read(editorStateProvider).hasUnsavedEdits, isFalse);
    expect(editor.elements, isEmpty);

    await tester.ensureVisible(find.byKey(const Key('editor-mode-draw')));
    await tester.tap(find.byKey(const Key('editor-mode-draw')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editor-header-undo')));
    await tester.pump();
    expect(editor.elements, hasLength(1));
    expect(container.read(editorStateProvider).hasUnsavedEdits, isTrue);
    await tester.tap(find.byKey(const Key('editor-header-redo')));
    await tester.pump();
    expect(editor.elements, isEmpty);
    expect(container.read(editorStateProvider).hasUnsavedEdits, isFalse);
  });

  for (final mode in ['crop', 'draw', 'text', 'stickers']) {
    testWidgets('two-finger zoom/pan in $mode leaves crop and annotations untouched', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpEditor(tester);
      await selectMode(tester, mode);
      final canvas = find.byType(AnnotationCanvas);
      final editor = tester.widget<AnnotationCanvas>(canvas).editor;
      final container = ProviderScope.containerOf(tester.element(canvas));
      final crop = container.read(editorStateProvider).crop;
      final photoBefore = screenRect(tester, canvas);
      await pinchAndPan(tester, photoBefore.center);
      final photoAfter = screenRect(tester, canvas);
      expect(photoAfter.width, closeTo(photoBefore.width * 2, .001));
      expect(photoAfter.height, closeTo(photoBefore.height * 2, .001));
      expect(photoAfter.center.dx, closeTo(photoBefore.center.dx + 30, .001));
      expect(editor.elements, isEmpty);
      expect(editor.canUndo, isFalse);
      expect(container.read(editorStateProvider).crop, crop);
      expect(container.read(editorStateProvider).hasUnsavedEdits, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('drawing after zoom, rotation and reflection uses image coordinates; resize resets only the viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpEditor(tester);
    await tester.tap(find.byIcon(Icons.rotate_left));
    await tester.pumpAndSettle();
    final canvas = find.byType(AnnotationCanvas);
    final container = ProviderScope.containerOf(tester.element(canvas));
    container.read(editorStateProvider.notifier).flipHorizontally();
    final flipped = container.read(editorStateProvider);
    await tester.ensureVisible(find.byKey(const Key('editor-mode-draw')));
    await tester.tap(find.byKey(const Key('editor-mode-draw')));
    await tester.pumpAndSettle();
    await pinchAndPan(tester, screenRect(tester, canvas).center);
    final box = tester.renderObject<RenderBox>(canvas);
    final start = box.localToGlobal(Offset(box.size.width * .4, box.size.height * .4));
    final end = box.localToGlobal(Offset(box.size.width * .6, box.size.height * .6));
    await tester.dragFrom(start, end - start);
    await tester.pump();
    final editor = tester.widget<AnnotationCanvas>(canvas).editor;
    final points = editor.elements.single.points;
    expect(points.first.dx, closeTo(.4, .001));
    expect(points.first.dy, closeTo(.4, .001));
    expect(points.last.dx, closeTo(.6, .001));
    expect(points.last.dy, closeTo(.6, .001));

    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(editor.elements.single.points, points);
    final viewport = tester.getRect(find.byKey(const Key('editor-preview-viewport')));
    final photo = screenRect(tester, canvas);
    final fitted = applyBoxFit(BoxFit.contain, const Size(1, 1), viewport.size).destination;
    expect(photo.width, closeTo(fitted.width, .001));
    expect(photo.height, closeTo(fitted.height, .001));
    expect(photo.center.dx, closeTo(viewport.center.dx, .001));
    expect(photo.center.dy, closeTo(viewport.center.dy, .001));
    expect(container.read(editorStateProvider).rotationAngle, -90);
    expect(container.read(editorStateProvider).flipHorizontal, flipped.flipHorizontal);
    expect(container.read(editorStateProvider).flipVertical, flipped.flipVertical);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pinch starting outside the photo cancels a stroke already being drawn', (tester) async {
    await pumpEditor(tester, image: Image.memory(await imageBytes(tester, const Size(400, 100))));
    await tester.ensureVisible(find.byKey(const Key('editor-mode-draw')));
    await tester.tap(find.byKey(const Key('editor-mode-draw')));
    await tester.pumpAndSettle();
    final canvas = find.byType(AnnotationCanvas);
    final editor = tester.widget<AnnotationCanvas>(canvas).editor;
    final center = screenRect(tester, canvas).center;
    final viewport = tester.getRect(find.byKey(const Key('editor-preview-viewport')));
    final first = await tester.startGesture(center - const Offset(40, 0), pointer: 1);
    await first.moveBy(const Offset(30, 0));
    await tester.pump();
    final second = await tester.startGesture(Offset(center.dx, viewport.top + 5), pointer: 2);
    await second.moveBy(const Offset(0, -40));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();
    expect(editor.elements, isEmpty);
    expect(editor.canUndo, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinching crop corners preserves an existing crop selection', (tester) async {
    await pumpEditor(tester);
    final canvas = find.byType(AnnotationCanvas);
    final container = ProviderScope.containerOf(tester.element(canvas));
    const crop = Rect.fromLTRB(.2, .2, .8, .8);
    container.read(editorStateProvider.notifier).setCrop(crop);
    await tester.pump();
    final box = tester.renderObject<RenderBox>(canvas);
    final first = await tester.startGesture(
      box.localToGlobal(Offset(box.size.width * .2, box.size.height * .2)),
      pointer: 1,
    );
    final second = await tester.startGesture(
      box.localToGlobal(Offset(box.size.width * .8, box.size.height * .8)),
      pointer: 2,
    );
    await first.moveBy(const Offset(-30, -30));
    await second.moveBy(const Offset(30, 30));
    await tester.pump();
    expect(container.read(editorStateProvider).crop, crop);
    expect(tester.widget<CropImage>(find.byType(CropImage)).controller!.crop, crop);
    await first.up();
    await second.moveBy(const Offset(10, 10));
    await second.up();
    await tester.pump();
    expect(container.read(editorStateProvider).crop, crop);
    expect(tester.takeException(), isNull);
  });
  testWidgets('four visible sections and compact drawing strip keep the required tools and top history', (
    tester,
  ) async {
    await pumpEditor(tester);
    final bar = find.byKey(const Key('editor-mode-bar'));
    final buttons = tester.widgetList<TextButton>(find.descendant(of: bar, matching: find.byType(TextButton)));
    expect(buttons.map((button) => (button.key! as ValueKey<String>).value), [
      'editor-mode-crop',
      'editor-mode-draw',
      'editor-mode-text',
      'editor-mode-magicEraser',
    ]);
    expect(find.byKey(const Key('editor-back')), findsOneWidget);
    expect(find.byKey(const Key('editor-save')), findsOneWidget);
    expect(find.byKey(const Key('editor-more')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('editor-mode-draw')));
    await tester.tap(find.byKey(const Key('editor-mode-draw')));
    await tester.pumpAndSettle();
    final pill = find.byKey(const Key('editor-drawing-pill'));
    final tools = tester.widgetList<IconButton>(find.descendant(of: pill, matching: find.byType(IconButton)));
    expect(tools.map((tool) => (tool.key! as ValueKey<String>).value), [
      'editor-tool-pen',
      'editor-tool-highlighter',
      'editor-tool-brush',
      'editor-tool-eraser',
      'editor-toggle-settings',
    ]);
    await tester.tap(find.byKey(const Key('editor-tool-highlighter')));
    await tester.pump();
    var canvas = tester.widget<AnnotationCanvas>(find.byType(AnnotationCanvas));
    expect(canvas.tool, AnnotationTool.highlighter);
    expect(canvas.color, Colors.purple);
    expect(canvas.opacity, .45);
    await tester.tap(find.byKey(const Key('editor-tool-eraser')));
    await tester.pump();
    canvas = tester.widget<AnnotationCanvas>(find.byType(AnnotationCanvas));
    expect(canvas.tool, AnnotationTool.eraser);
    expect(magicEraser, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sticker layers select, reorder, delete and undo through the shared document history', (tester) async {
    await pumpEditor(tester);
    await selectMode(tester, 'stickers');
    await tester.tap(find.byKey(const Key('editor-sticker-star')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('editor-sticker-heart')));
    await tester.pump();
    final editor = tester.widget<AnnotationCanvas>(find.byType(AnnotationCanvas)).editor;
    expect(editor.elements.map((e) => e.text), ['star', 'heart']);
    await tester.ensureVisible(find.byKey(const Key('editor-more')));
    await tester.tap(find.byKey(const Key('editor-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Layers'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send backward').first);
    await tester.pump();
    expect(editor.elements.map((e) => e.text), ['heart', 'star']);
    await tester.tap(find.byTooltip('Delete layer').first);
    await tester.pump();
    expect(editor.elements.map((e) => e.text), ['heart']);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editor-header-undo')));
    await tester.pump();
    expect(editor.elements.map((e) => e.text), ['heart', 'star']);
    await tester.tap(find.byKey(const Key('editor-header-undo')));
    await tester.pump();
    expect(editor.elements.map((e) => e.text), ['star', 'heart']);
    expect(tester.takeException(), isNull);
  });
  testWidgets('text outline background size opacity and font update the selected layer and are undoable', (
    tester,
  ) async {
    final original = await addTextAnnotation(tester);
    final canvas = find.byType(AnnotationCanvas);
    final editor = tester.widget<AnnotationCanvas>(canvas).editor;
    await tester.ensureVisible(find.byKey(const Key('editor-text-outline')));
    await tester.tap(find.byKey(const Key('editor-text-outline')));
    await tester.pump();
    expect(editor.elements.single.outlineWidth, greaterThan(0));
    await tester.ensureVisible(find.byKey(const Key('editor-text-background')));
    await tester.tap(find.byKey(const Key('editor-text-background')));
    await tester.pump();
    expect(editor.elements.single.backgroundColor.a, 1);
    await tester.ensureVisible(find.byKey(const Key('editor-font')));
    await tester.tap(find.byKey(const Key('editor-font')));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((widget) => widget is Text && widget.style?.fontFamily == 'serif').last);
    await tester.pumpAndSettle();
    expect(editor.elements.single.fontFamily, 'serif');
    final size = find.byKey(const Key('editor-text-size'));
    await tester.ensureVisible(size);
    await tester.tapAt(tester.getCenter(size));
    await tester.pumpAndSettle();
    expect(editor.elements.single.fontSize, isNot(original.fontSize));
    final opacity = find.byKey(const Key('annotation-opacity'));
    await tester.ensureVisible(opacity);
    await tester.tapAt(tester.getCenter(opacity));
    await tester.pumpAndSettle();
    expect(editor.elements.single.opacity, lessThan(1));
    expect(editor.elements.single.points, original.points);
    final container = ProviderScope.containerOf(tester.element(canvas));
    for (var i = 0; i < 5; i++) {
      container.read(editorStateProvider.notifier).undo();
    }
    await tester.pump();
    expect(editor.elements.single, original);
    expect(tester.takeException(), isNull);
  });
}
