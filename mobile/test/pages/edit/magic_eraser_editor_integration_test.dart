import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crop_image/crop_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/presentation/pages/edit/annotation_canvas.dart';
import 'package:immich_mobile/presentation/pages/edit/edit.page.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
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
  final magicEraser = find.byKey(const Key('magic-eraser-editor-action'));
  final retry = find.byKey(const Key('magic-eraser-capability-retry'));

  setUp(() {
    TestUtils.init();
    repository = _MockMagicEraserRepository();
    asset = TestUtils.createRemoteAsset(id: 'asset-id', width: 1, height: 1);
    when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => false);
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
    }
  }

  Future<void> selectMagicEraser(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('editor-mode-magicEraser')));
    await tester.ensureVisible(find.byKey(const Key('editor-mode-magicEraser')));
    await tester.tap(find.byKey(const Key('editor-mode-magicEraser')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('an older or unconfigured server disables only Magic Eraser while keeping the crop editor usable', (
    tester,
  ) async {
    await pumpEditor(tester);

    expect(find.byType(CropImage), findsOneWidget);
    expect(find.byIcon(Icons.rotate_left), findsOneWidget);
    expect(find.byIcon(Icons.rotate_right), findsOneWidget);
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.rotate_left));
    await tester.pump();
    final state = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('editor-mode-crop'))),
    ).read(editorStateProvider);
    expect(state.rotationAngle, -90);
    expect(state.hasUnsavedEdits, isTrue);

    await selectMagicEraser(tester);
    expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNull);
    expect(find.text('Magic eraser is unavailable for this photo or server.'), findsOneWidget);
    expect(retry, findsOneWidget);
  });

  testWidgets('saving opens copy, disabled replacement, and cancel choices', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.byIcon(Icons.rotate_left));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.done_rounded));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byKey(const Key('edit-save-mode-dialog')), findsOneWidget);
    expect(find.byKey(const Key('edit-save-copy')), findsOneWidget);
    expect(find.byKey(const Key('edit-replace-original')), findsOneWidget);
    expect(tester.widget<ListTile>(find.byKey(const Key('edit-replace-original'))).enabled, isFalse);
    expect(find.byKey(const Key('edit-save-cancel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('edit-save-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-save-mode-dialog')), findsNothing);
  });

  testWidgets('an unavailable optional AI service leaves ordinary transform editing operational', (tester) async {
    when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenThrow(StateError('Offline'));

    await pumpEditor(tester);
    await selectMagicEraser(tester);

    expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNull);
    expect(find.byType(CropImage), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('editor-mode-crop')));
    await tester.tap(find.byKey(const Key('editor-mode-crop')));
    await tester.pump();
    expect(find.byIcon(Icons.rotate_left), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a slow capability check stays disabled and visibly loading until confirmed', (tester) async {
    final pending = Completer<bool>();
    when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) => pending.future);

    await pumpEditor(tester);
    await selectMagicEraser(tester);

    expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNull);
    expect(find.text('Checking magic eraser availability…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(retry, findsNothing);
    expect(find.byType(CropImage), findsOneWidget);

    pending.complete(true);
    await tester.pump();

    expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNotNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  for (final (error, message) in <(Object, String)>[
    (api.ApiException(401, 'Private response'), 'Sign in again to check magic eraser availability.'),
    (api.ApiException(403, 'Private response'), 'You do not have permission to edit this photo.'),
    (api.ApiException(400, 'Private response'), 'Magic eraser does not support this photo.'),
    (
      api.ApiException(500, 'Private response'),
      'Could not check magic eraser availability. Check your connection and retry.',
    ),
    (
      api.ApiException(503, 'Private response'),
      'Could not check magic eraser availability. Check your connection and retry.',
    ),
    (
      http.ClientException('Private URL'),
      'Could not check magic eraser availability. Check your connection and retry.',
    ),
    (http.RequestAbortedException(), 'Could not check magic eraser availability. Check your connection and retry.'),
    (
      const FormatException('Private payload'),
      'Could not check magic eraser availability. Check your connection and retry.',
    ),
  ]) {
    testWidgets(
      'a ${error is api.ApiException ? error.code : error.runtimeType} failure explains why and permits retry',
      (tester) async {
        when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenThrow(error);

        await pumpEditor(tester);
        await selectMagicEraser(tester);

        expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNull);
        expect(find.text(message), findsOneWidget);
        expect(retry, findsOneWidget);
        expect(find.textContaining('Private'), findsNothing);
        expect(find.byType(CropImage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final initiallyDisabled in [true, false]) {
    testWidgets('retry recovers from ${initiallyDisabled ? 'disabled' : 'offline'} without losing crop or rotation', (
      tester,
    ) async {
      if (!initiallyDisabled) {
        when(
          () => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger')),
        ).thenThrow(http.ClientException('Offline'));
      }
      await pumpEditor(tester);
      await selectMagicEraser(tester);
      final container = ProviderScope.containerOf(tester.element(magicEraser));
      container.read(editorStateProvider.notifier).setCrop(const Rect.fromLTRB(0.1, 0.1, 0.9, 0.9));
      container.read(editorStateProvider.notifier).rotateCCW();
      await tester.pumpAndSettle();
      final before = container.read(editorStateProvider);
      final pending = Completer<bool>();
      when(
        () => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger')),
      ).thenAnswer((_) => pending.future);

      await tester.tap(retry);
      await tester.pump();

      expect(retry, findsNothing);
      expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNull);
      verify(() => repository.isEnabled(asset.id, abortTrigger: any(named: 'abortTrigger'))).called(2);
      pending.complete(true);
      await tester.pumpAndSettle();

      expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNotNull);
      final after = container.read(editorStateProvider);
      expect(after.crop, before.crop);
      expect(after.rotationAngle, before.rotationAngle);
      expect(after.hasUnsavedEdits, isTrue);
    });
  }

  testWidgets('saving transform edits disables capability retry and AI navigation', (tester) async {
    await pumpEditor(tester);
    await selectMagicEraser(tester);
    final container = ProviderScope.containerOf(tester.element(magicEraser));
    container.read(editorStateProvider.notifier).setIsEditing(true);
    await tester.pump();

    expect(tester.widget<TextButton>(retry).onPressed, isNull);
    when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => true);
    container.invalidate(magicEraserEnabledProvider(asset.id));
    await tester.pump();
    await tester.pump();

    expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNull);
  });

  testWidgets('rechecking an enabled capability does not reuse a stale enabled result', (tester) async {
    when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => true);
    await pumpEditor(tester);
    await selectMagicEraser(tester);
    expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNotNull);
    final pending = Completer<bool>();
    when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) => pending.future);
    final container = ProviderScope.containerOf(tester.element(magicEraser));

    container.invalidate(magicEraserEnabledProvider(asset.id));
    await tester.pump();

    expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNull);
    expect(find.text('Checking magic eraser availability…'), findsOneWidget);
    pending.complete(false);
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNull);
    expect(retry, findsOneWidget);
  });

  testWidgets('Russian availability and retry fit a narrow screen with enlarged text', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    when(
      () => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger')),
    ).thenThrow(http.ClientException('Offline'));
    await pumpEditor(tester);
    await selectMagicEraser(tester);

    await EasyLocalization.of(tester.element(magicEraser))!.setLocale(const Locale('ru'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();

    expect(
      find.text('Не удалось проверить доступность волшебного ластика. Проверьте соединение и повторите попытку.'),
      findsOneWidget,
    );
    expect(find.text('Повторить'), findsOneWidget);
    expect(tester.getRect(retry).right, lessThanOrEqualTo(320));
    expect(tester.getRect(retry).bottom, lessThanOrEqualTo(720));
  });

  testWidgets('Live/Motion stills expose AI copies without enabling crop or overwrite controls', (tester) async {
    when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => true);
    final live = asset.copyWith(livePhotoVideoId: 'paired-video-id');

    await pumpEditor(tester, photo: live);

    expect(tester.widget<OutlinedButton>(magicEraser).onPressed, isNotNull);
    expect(find.byType(CropImage), findsNothing);
    expect(find.byIcon(Icons.rotate_left), findsNothing);
    expect(find.byIcon(Icons.rotate_right), findsNothing);
    expect(find.byIcon(Icons.done_rounded), findsNothing);
    expect(live.isEditable, isFalse);
    expect(live.livePhotoVideoId, 'paired-video-id');
  });

  testWidgets('existing editor callers without an asset retain their original crop interface', (tester) async {
    await pumpEditor(tester, legacyCaller: true);

    expect(magicEraser, findsNothing);
    expect(find.byType(CropImage), findsOneWidget);
    expect(find.byIcon(Icons.rotate_left), findsOneWidget);
    verifyNever(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger')));
  });

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
      expect(tester.getRect(canvas).bottom, lessThanOrEqualTo(tester.getRect(panel).top));
      expect(find.byKey(const Key('editor-markup-controls')), findsNothing);
      expect(magicEraser, findsNothing);
      expect(find.byKey(const Key('annotation-toggle')), findsNothing);

      await tester.ensureVisible(find.byKey(const Key('editor-mode-draw')));
      await tester.tap(find.byKey(const Key('editor-mode-draw')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editor-markup-controls')), findsOneWidget);
      expect(find.byIcon(Icons.rotate_left), findsNothing);
      expect(magicEraser, findsNothing);
      expect(tester.getRect(canvas).bottom, lessThanOrEqualTo(tester.getRect(panel).top));
      final viewport = tester.getRect(find.byKey(const Key('editor-preview-viewport')));
      final fitted = applyBoxFit(BoxFit.contain, const Size(1, 1), viewport.size).destination;
      expect(tester.getSize(canvas), fitted);
      expect(tester.getCenter(canvas), viewport.center);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (locale, titles) in {
    'en': ['Magic eraser', 'Crop', 'Filters', 'Draw', 'Stickers', 'Text'],
    'ru': ['Волшебный ластик', 'Обрезать', 'Фильтры', 'Рисование', 'Стикеры', 'Текст'],
  }.entries.map((entry) => (entry.key, entry.value))) {
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

          const modes = ['magicEraser', 'crop', 'filters', 'draw', 'stickers', 'text'];
          for (var index = 0; index < modes.length; index++) {
            final mode = modes[index];
            final button = find.byKey(Key('editor-mode-$mode'));
            await tester.ensureVisible(button);
            await tester.tap(button);
            await tester.pumpAndSettle();
            expect(tester.widget<Text>(find.byKey(const Key('editor-mode-title'))).data, titles[index]);
            expect(find.descendant(of: button, matching: find.byType(Text)), findsOneWidget);
            final viewport = tester.getRect(find.byKey(const Key('editor-preview-viewport')));
            final appBar = tester.getRect(find.byType(AppBar));
            final panel = tester.getRect(find.byKey(const Key('editor-bottom-panel')));
            final bar = tester.getRect(find.byKey(const Key('editor-mode-bar')));
            expect(viewport.top, closeTo(appBar.bottom, .01));
            expect(viewport.bottom, closeTo(panel.top, .01));
            expect(viewport.height, greaterThanOrEqualTo((size.height - appBar.bottom) / 2 - .01));
            expect(panel.bottom, closeTo(size.height, .01));
            expect(bar.bottom, closeTo(panel.bottom, .01));
            expect(bar.height, greaterThanOrEqualTo(64));
            expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
            final markup = mode == 'draw' || mode == 'text' || mode == 'stickers';
            expect(find.byKey(const Key('editor-markup-controls')), markup ? findsOneWidget : findsNothing);
            expect(find.byIcon(Icons.rotate_left), mode == 'crop' ? findsOneWidget : findsNothing);
            expect(magicEraser, mode == 'magicEraser' ? findsOneWidget : findsNothing);
            if (markup) {
              final slider = find.byKey(Key(mode == 'draw' ? 'annotation-width' : 'annotation-opacity'));
              await tester.ensureVisible(slider);
              await tester.pumpAndSettle();
              final sliderRect = tester.getRect(slider);
              expect(sliderRect.top, greaterThanOrEqualTo(panel.top));
              expect(sliderRect.bottom, lessThanOrEqualTo(bar.top));
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
    await tester.ensureVisible(find.byKey(const Key('editor-mode-stickers')));
    await tester.tap(find.byKey(const Key('editor-mode-stickers')));
    await tester.pumpAndSettle();
    expect(tester.widget<AnnotationCanvas>(canvas).editor, same(editor));
    expect(editor.elements.single, original);
    await tester.tap(find.byKey(const Key('annotation-undo')));
    await tester.pump();
    expect(editor.elements, isEmpty);
    await tester.tap(find.byKey(const Key('annotation-redo')));
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

    await tester.tap(find.byKey(const Key('annotation-undo')));
    await tester.pump();
    expect(editor.elements.single, original);
    await tester.tap(find.byKey(const Key('annotation-redo')));
    await tester.pump();
    expect(editor.elements.single, edited);
    await tester.tap(find.byKey(const Key('annotation-undo')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('annotation-undo')));
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
      await tester.tap(find.byKey(const Key('annotation-undo')));
      await tester.pump();
      expect(editor.elements, isEmpty);
      expect(editor.canUndo, isFalse);
      await tester.tap(find.byKey(const Key('annotation-redo')));
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
    await tester.tap(find.byKey(const Key('annotation-undo')));
    await tester.pump();
    expect(editor.elements.single, original);
    await tester.tap(find.byKey(const Key('annotation-redo')));
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

    await tester.tap(find.byKey(const Key('annotation-undo')));
    await tester.pump();
    expect(editor.elements, isEmpty);
    expect(container.read(editorStateProvider).hasUnsavedEdits, isFalse);

    await tester.tap(find.byKey(const Key('annotation-redo')));
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
    await tester.tap(find.byKey(const Key('editor-reset')));
    await tester.pumpAndSettle();
    expect(container.read(editorStateProvider).crop, baseline.crop);
    expect(container.read(editorStateProvider).rotationAngle, baseline.rotationAngle);
    expect(container.read(editorStateProvider).hasUnsavedEdits, isFalse);
    expect(editor.elements, isEmpty);

    await tester.ensureVisible(find.byKey(const Key('editor-mode-draw')));
    await tester.tap(find.byKey(const Key('editor-mode-draw')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('annotation-undo')));
    await tester.pump();
    expect(editor.elements, hasLength(1));
    expect(container.read(editorStateProvider).hasUnsavedEdits, isTrue);
    await tester.tap(find.byKey(const Key('annotation-redo')));
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
      await tester.ensureVisible(find.byKey(Key('editor-mode-$mode')));
      await tester.tap(find.byKey(Key('editor-mode-$mode')));
      await tester.pumpAndSettle();
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
  testWidgets('six-section rail and drawing pill match the required order and top actions', (tester) async {
    await pumpEditor(tester);
    final bar = find.byKey(const Key('editor-mode-bar'));
    final buttons = tester.widgetList<TextButton>(find.descendant(of: bar, matching: find.byType(TextButton)));
    expect(buttons.map((button) => (button.key! as ValueKey<String>).value), [
      'editor-mode-magicEraser',
      'editor-mode-crop',
      'editor-mode-filters',
      'editor-mode-draw',
      'editor-mode-stickers',
      'editor-mode-text',
    ]);
    expect(find.byKey(const Key('editor-reset')), findsOneWidget);
    expect(find.byKey(const Key('editor-save')), findsOneWidget);
    expect(find.byKey(const Key('editor-more')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const Key('editor-mode-magicEraser')), matching: find.text('AI')),
      findsOneWidget,
    );
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
      'annotation-undo',
      'annotation-redo',
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
    await tester.ensureVisible(find.byKey(const Key('editor-mode-stickers')));
    await tester.tap(find.byKey(const Key('editor-mode-stickers')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editor-sticker-star')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('editor-sticker-heart')));
    await tester.pump();
    final editor = tester.widget<AnnotationCanvas>(find.byType(AnnotationCanvas)).editor;
    expect(editor.elements.map((e) => e.text), ['star', 'heart']);
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
    await tester.tap(find.byKey(const Key('annotation-undo')));
    await tester.pump();
    expect(editor.elements.map((e) => e.text), ['heart', 'star']);
    await tester.tap(find.byKey(const Key('annotation-undo')));
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
