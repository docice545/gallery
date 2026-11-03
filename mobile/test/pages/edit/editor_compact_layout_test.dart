import 'dart:ui' as ui;

import 'package:crop_image/crop_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/pages/edit/annotation_canvas.dart';
import 'package:immich_mobile/presentation/pages/edit/edit.page.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';

import '../../fixtures/editor_raster.dart';
import '../../test_utils.dart';
import '../../widget_tester_extensions.dart';

Future<void> pumpCompactEditor(
  WidgetTester tester, {
  Size size = const Size(393, 852),
  double scale = 1,
  bool portrait = false,
  bool russian = false,
  FakeViewPadding padding = const FakeViewPadding(top: 28, bottom: 24),
}) async {
  TestUtils.init();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  final raster = (await tester.runAsync(createEditorRaster))!;
  addTearDown(raster.dispose);
  var image = raster;
  if (portrait) {
    image = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(raster, const Rect.fromLTWH(0, 0, 64, 48), const Rect.fromLTWH(0, 0, 360, 640), Paint());
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(360, 640);
      } finally {
        picture.dispose();
      }
    }))!;
    addTearDown(image.dispose);
  }
  final bytes = (await tester.runAsync(() => EditedImageExporter.encodePng(image)))!;
  await tester.runAsync(
    () => tester.pumpConsumerWidgetRaw(
      RepaintBoundary(
        key: const Key('compact-editor-screen'),
        child: EditImagePage(
          image: Image.memory(bytes),
          applyEdits: (_) => throw StateError('Layout tests must not replace originals'),
        ),
      ),
      overrides: [
        immichThemeProvider.overrideWith(
          (ref) => ImmichTheme(
            light: ColorScheme.fromSeed(seedColor: Colors.blue),
            dark: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
          ),
        ),
      ],
    ),
  );
  for (var i = 0; i < 100 && find.byType(CropImage).evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(find.byType(CropImage), findsOneWidget);
  if (russian) {
    await EasyLocalization.of(tester.element(find.byType(EditImagePage)))!.setLocale(const Locale('ru'));
  }
  await tester.pumpAndSettle();
}

Future<void> tapEditorControl(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> selectEditorMode(WidgetTester tester, String mode) async {
  if (find.byKey(const Key('editor-tools-back')).evaluate().isNotEmpty) {
    await tapEditorControl(tester, 'editor-tools-back');
  }
  await tapEditorControl(tester, 'editor-mode-$mode');
}

Rect editorPhotoRect(WidgetTester tester) => tester.getRect(find.byKey(const Key('editor-preview-viewport')));

void expectEditorGeometry(WidgetTester tester, Rect photo, double dockHeight) {
  expect(editorPhotoRect(tester), photo, reason: 'Tool depth must not resize or move the photo viewport');
  expect(tester.getSize(find.byKey(const Key('editor-bottom-panel'))).height, dockHeight);
  expect(find.byKey(const Key('editor-fixed-dock')), findsOneWidget);
  expect(find.byKey(const Key('editor-parameter-popover')), findsAtMostNWidgets(1));
  expect(find.byKey(const Key('editor-active-settings')), findsNothing);
  expect(find.byKey(const Key('editor-markup-controls')), findsAtMostNWidgets(1));
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('GoogleSans');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      font.addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-$weight.ttf'));
    }
    await font.load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final (size, padding, scale) in [
      (const Size(393, 852), const FakeViewPadding(top: 28, bottom: 24), 1.0),
      (const Size(320, 720), const FakeViewPadding(top: 28, bottom: 24), 2.0),
      (const Size(568, 320), const FakeViewPadding(left: 44, right: 44, bottom: 24), 2.0),
    ]) {
      testWidgets(
        'one fixed dock and invariant photo across nested tools on $platform $size scale=$scale',
        (tester) async {
          await pumpCompactEditor(tester, size: size, padding: padding, scale: scale, portrait: true, russian: true);
          final photo = editorPhotoRect(tester);
          final dockHeight = tester.getSize(find.byKey(const Key('editor-bottom-panel'))).height;
          expect(dockHeight, 56 + padding.bottom);
          expect(photo.width, closeTo(size.width - padding.left - padding.right, .01));
          expect(photo.height, closeTo(size.height - padding.top - kToolbarHeight - dockHeight, .01));
          expect(
            find.descendant(of: find.byKey(const Key('editor-mode-bar')), matching: find.byType(Text)),
            findsNothing,
          );
          for (var repeat = 0; repeat < 2; repeat++) {
            await selectEditorMode(tester, 'draw');
            expect(find.byKey(const Key('editor-mode-bar')), findsNothing, reason: 'Category row must be replaced');
            for (final tool in ['pen', 'highlighter', 'brush', 'eraser']) {
              await tapEditorControl(tester, 'editor-tool-$tool');
              expectEditorGeometry(tester, photo, dockHeight);
            }
            for (final option in ['width', 'color', 'opacity']) {
              await tapEditorControl(tester, 'editor-$option');
              expect(find.byKey(const Key('editor-parameter-popover')), findsOneWidget);
              expectEditorGeometry(tester, photo, dockHeight);
              final popover = tester.getRect(find.byKey(const Key('editor-parameter-popover')));
              expect(popover.height, lessThanOrEqualTo(160));
              expect(popover.bottom, lessThan(photo.bottom));
              expect(find.byKey(const Key('editor-tools-back')).hitTestable(), findsOneWidget);
              await tester.tapAt(const Offset(1, 1));
              await tester.pumpAndSettle();
              expect(find.byKey(const Key('editor-parameter-popover')), findsNothing);
              expectEditorGeometry(tester, photo, dockHeight);
            }
            await selectEditorMode(tester, 'crop');
            await tapEditorControl(tester, 'editor-crop-frame');
            expectEditorGeometry(tester, photo, dockHeight);
            await tester.tapAt(const Offset(1, 1));
            await tester.pumpAndSettle();
            await selectEditorMode(tester, 'text');
            await tapEditorControl(tester, 'editor-text-options');
            expectEditorGeometry(tester, photo, dockHeight);
            await tapEditorControl(tester, 'editor-tools-back');
            expect(find.byKey(const Key('editor-mode-bar')), findsOneWidget);
            expectEditorGeometry(tester, photo, dockHeight);
          }
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }

  testWidgets('nested options preserve pixels, drawing, zoom transform, crop controller and undo/redo', (tester) async {
    await pumpCompactEditor(tester, portrait: true);
    await selectEditorMode(tester, 'draw');
    final canvas = find.byType(AnnotationCanvas);
    final container = ProviderScope.containerOf(tester.element(canvas));
    final box = tester.getRect(canvas);
    await tester.dragFrom(
      box.topLeft + Offset(box.width * .3, box.height * .3),
      Offset(box.width * .3, box.height * .3),
    );
    await tester.pumpAndSettle();
    final drawing = container.read(editorStateProvider).annotations.single;
    final photo = editorPhotoRect(tester);
    final controller = tester.widget<CropImage>(find.byType(CropImage)).controller;
    final first = await tester.startGesture(photo.center - const Offset(30, 0), pointer: 1);
    final second = await tester.startGesture(photo.center + const Offset(30, 0), pointer: 2);
    await first.moveBy(const Offset(-30, 0));
    await second.moveBy(const Offset(30, 0));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    final transform = tester.widget<Transform>(find.byKey(const Key('editor-zoom-transform'))).transform.clone();
    expect(transform.getMaxScaleOnAxis(), greaterThan(1));
    for (final mode in ['text', 'crop', 'draw']) {
      await selectEditorMode(tester, mode);
      expect(editorPhotoRect(tester), photo);
      expect(tester.widget<Transform>(find.byKey(const Key('editor-zoom-transform'))).transform, transform);
      expect(tester.widget<CropImage>(find.byType(CropImage)).controller, same(controller));
      expect(container.read(editorStateProvider).annotations.single, drawing);
    }
    await tapEditorControl(tester, 'editor-width');
    expect(editorPhotoRect(tester), photo);
    final slider = find.byKey(const Key('annotation-width'));
    await tester.tap(slider);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('editor-parameter-popover')), findsNothing);
    expect(container.read(editorStateProvider).annotations.single, drawing);
    await tapEditorControl(tester, 'editor-header-undo');
    expect(container.read(editorStateProvider).annotations, isEmpty);
    await tapEditorControl(tester, 'editor-header-redo');
    expect(container.read(editorStateProvider).annotations.single, drawing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard temporarily resizes once and restores the exact photo rectangle and document', (tester) async {
    await pumpCompactEditor(tester, size: const Size(320, 720), scale: 2);
    await selectEditorMode(tester, 'text');
    final photo = editorPhotoRect(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
    final state = container.read(editorStateProvider);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    tester.view.padding = const FakeViewPadding(top: 28);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('editor-bottom-panel'))).height, 56);
    expect(editorPhotoRect(tester).bottom, closeTo(720 - 280 - 56, .01));
    expect(container.read(editorStateProvider), state);
    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
    await tester.pumpAndSettle();
    expect(editorPhotoRect(tester), photo);
    expect(container.read(editorStateProvider), state);
    expect(tester.takeException(), isNull);
  });

  testWidgets('orientation preserves the retained crop controller and edits', (tester) async {
    await pumpCompactEditor(tester, portrait: true);
    final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
    container.read(editorStateProvider.notifier).setCrop(const Rect.fromLTRB(.1, .1, .9, .9));
    container.read(editorStateProvider.notifier).rotateCW();
    await tester.pumpAndSettle();
    final before = container.read(editorStateProvider);
    final controller = tester.widget<CropImage>(find.byType(CropImage)).controller;
    tester.view.physicalSize = const Size(852, 393);
    tester.view.padding = const FakeViewPadding(left: 44, right: 44, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(left: 44, right: 44, bottom: 24);
    await tester.pumpAndSettle();
    expect(tester.widget<CropImage>(find.byType(CropImage)).controller, same(controller));
    expect(container.read(editorStateProvider), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('review images and measured viewport at every editor depth', (tester) async {
    await pumpCompactEditor(tester, russian: true, portrait: true);
    final baseline = editorPhotoRect(tester);
    Future<void> capture(String name) async {
      final photo = editorPhotoRect(tester);
      final dock = tester.getRect(find.byKey(const Key('editor-bottom-panel')));
      expect(photo, baseline);
      debugPrint('EDITOR_VIEWPORT $name photo=${photo.toString()} dock=${dock.toString()}');
      await expectLater(find.byType(Overlay), matchesGoldenFile('goldens/fixed_dock_$name.png'));
    }

    await capture('entry');
    await selectEditorMode(tester, 'draw');
    await capture('markup');
    await tapEditorControl(tester, 'editor-tool-highlighter');
    await capture('marker');
    await tapEditorControl(tester, 'editor-width');
    await capture('width');
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    await tapEditorControl(tester, 'editor-color');
    await capture('color');
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    await selectEditorMode(tester, 'crop');
    await capture('crop');
    await selectEditorMode(tester, 'text');
    await capture('text');
  });
}
