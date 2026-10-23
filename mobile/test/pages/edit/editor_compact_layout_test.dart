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
    for (final size in [const Size(393, 852), const Size(320, 720), const Size(852, 393)]) {
      testWidgets('compact editor: five tools visible without scrolling on $platform $size', (tester) async {
        await pumpCompactEditor(tester, size: size);
        final safe = Rect.fromLTRB(0, 28, size.width, size.height - 24);
        for (final name in ['crop', 'filters', 'draw', 'text', 'stickers']) {
          final target = find.byKey(Key('editor-mode-$name'));
          final rect = tester.getRect(target);
          expect(safe.contains(rect.topLeft), isTrue, reason: '$name top-left');
          expect(safe.contains(rect.bottomRight - const Offset(.01, .01)), isTrue, reason: '$name bottom-right');
          expect(target.hitTestable(), findsOneWidget, reason: '$name must not require ensureVisible');
        }
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));
    }
  }
  testWidgets('initial controls do not reserve half of the photo viewport', (tester) async {
    await pumpCompactEditor(tester);
    expect(tester.getSize(find.byKey(const Key('editor-bottom-panel'))).height, lessThanOrEqualTo(104));
    expect(tester.getSize(find.byKey(const Key('editor-preview-viewport'))).height, greaterThan(620));
    expect(find.byKey(const Key('editor-header-undo')), findsOneWidget);
    expect(find.byKey(const Key('editor-header-redo')), findsOneWidget);
    expect(find.byKey(const Key('editor-back')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('drawing settings expand and collapse without losing the document', (tester) async {
    await pumpCompactEditor(tester);
    await tester.tap(find.byKey(const Key('editor-mode-draw')));
    await tester.pumpAndSettle();
    final collapsed = tester.getSize(find.byKey(const Key('editor-preview-viewport')));
    for (final tool in ['pen', 'highlighter', 'brush', 'eraser']) {
      expect(find.byKey(Key('editor-tool-$tool')).hitTestable(), findsOneWidget);
    }
    expect(find.byKey(const Key('annotation-width')), findsNothing);
    await tester.tap(find.byKey(const Key('editor-toggle-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('annotation-width')), findsOneWidget);
    await tester.tap(find.byKey(const Key('editor-toggle-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('annotation-width')), findsNothing);
    expect(tester.getSize(find.byKey(const Key('editor-preview-viewport'))), collapsed);
    expect(tester.takeException(), isNull);
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('short landscape with cutouts keeps the drawing strip and five tools usable on $platform', (
      tester,
    ) async {
      await pumpCompactEditor(
        tester,
        size: const Size(568, 320),
        padding: const FakeViewPadding(left: 44, right: 44, bottom: 24),
      );
      await tester.tap(find.byKey(const Key('editor-mode-draw')));
      await tester.pumpAndSettle();
      for (final tool in ['pen', 'highlighter', 'brush', 'eraser']) {
        expect(find.byKey(Key('editor-tool-$tool')).hitTestable(), findsOneWidget);
      }
      for (final mode in ['crop', 'filters', 'draw', 'text', 'stickers']) {
        expect(find.byKey(Key('editor-mode-$mode')).hitTestable(), findsOneWidget);
      }
      expect(tester.getSize(find.byKey(const Key('editor-preview-viewport'))).height, greaterThan(100));
      await tester.tap(find.byKey(const Key('editor-toggle-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editor-toggle-settings')).hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('annotation-tool-picker')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
    testWidgets('short landscape keyboard temporarily collapses settings without losing edits on $platform', (
      tester,
    ) async {
      await pumpCompactEditor(
        tester,
        size: const Size(568, 320),
        padding: const FakeViewPadding(left: 44, right: 44, bottom: 24),
      );
      await tester.tap(find.byKey(const Key('editor-mode-text')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
      final before = container.read(editorStateProvider);
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      tester.view.padding = const FakeViewPadding(left: 44, right: 44);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editor-active-settings')), findsNothing);
      for (final mode in ['crop', 'filters', 'draw', 'text', 'stickers']) {
        expect(find.byKey(Key('editor-mode-$mode')).hitTestable(), findsOneWidget);
      }
      expect(container.read(editorStateProvider), before);
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editor-mode-bar')), findsNothing);
      expect(container.read(editorStateProvider), before);
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      tester.view.padding = const FakeViewPadding(left: 44, right: 44, bottom: 24);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editor-active-settings')), findsOneWidget);
      expect(container.read(editorStateProvider), before);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('drawing survives settings, undo/redo and orientation on $platform', (tester) async {
      await pumpCompactEditor(tester, portrait: true);
      await tester.tap(find.byKey(const Key('editor-mode-draw')));
      await tester.pumpAndSettle();
      final canvas = find.byType(AnnotationCanvas);
      final container = ProviderScope.containerOf(tester.element(canvas));
      final box = tester.renderObject<RenderBox>(canvas);
      final start = box.localToGlobal(Offset(box.size.width * .4, box.size.height * .4));
      final end = box.localToGlobal(Offset(box.size.width * .6, box.size.height * .6));
      await tester.dragFrom(start, end - start);
      await tester.pumpAndSettle();
      final drawing = container.read(editorStateProvider).annotations.single;
      expect(drawing.points.first.dx, closeTo(.4, .001));
      expect(drawing.points.first.dy, closeTo(.4, .001));
      expect(drawing.points.last.dx, closeTo(.6, .001));
      expect(drawing.points.last.dy, closeTo(.6, .001));
      await tester.tap(find.byKey(const Key('editor-toggle-settings')));
      await tester.pumpAndSettle();
      expect(container.read(editorStateProvider).annotations.single, drawing);
      await tester.tap(find.byKey(const Key('editor-header-undo')));
      await tester.pumpAndSettle();
      expect(container.read(editorStateProvider).annotations, isEmpty);
      await tester.tap(find.byKey(const Key('editor-header-redo')));
      await tester.pumpAndSettle();
      expect(container.read(editorStateProvider).annotations.single, drawing);
      tester.view.physicalSize = const Size(852, 393);
      await tester.pumpAndSettle();
      expect(container.read(editorStateProvider).annotations.single, drawing);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
    testWidgets('rotation between layouts preserves crop controller and history on $platform', (tester) async {
      await pumpCompactEditor(tester, portrait: true);
      final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
      final notifier = container.read(editorStateProvider.notifier);
      notifier.setCrop(const Rect.fromLTRB(.1, .1, .9, .9));
      notifier.rotateCW();
      await tester.pumpAndSettle();
      final before = container.read(editorStateProvider);
      final controller = tester.widget<CropImage>(find.byType(CropImage)).controller;
      tester.view.physicalSize = const Size(852, 393);
      tester.view.padding = const FakeViewPadding(left: 44, right: 44, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(left: 44, right: 44, bottom: 24);
      await tester.pumpAndSettle();
      expect(tester.widget<CropImage>(find.byType(CropImage)).controller, same(controller));
      expect(container.read(editorStateProvider), before);
      tester.view.physicalSize = const Size(393, 852);
      await tester.pumpAndSettle();
      expect(tester.widget<CropImage>(find.byType(CropImage)).controller, same(controller));
      expect(container.read(editorStateProvider), before);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
    testWidgets('keyboard insets resize once without changing the document on $platform', (tester) async {
      await pumpCompactEditor(tester, size: const Size(320, 720), scale: 2);
      final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
      final before = container.read(editorStateProvider);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      tester.view.padding = const FakeViewPadding(top: 28);
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.byKey(const Key('editor-mode-bar')));
      expect(bar.bottom, closeTo(440, .01));
      expect(tester.getSize(find.byKey(const Key('editor-preview-viewport'))).height, greaterThan(0));
      expect(container.read(editorStateProvider), before);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }
  for (final (name, platform, size, padding) in [
    ('android_portrait', TargetPlatform.android, const Size(393, 852), const FakeViewPadding(top: 28, bottom: 24)),
    ('ios_portrait', TargetPlatform.iOS, const Size(390, 844), const FakeViewPadding(top: 47, bottom: 34)),
    ('landscape', TargetPlatform.android, const Size(852, 393), const FakeViewPadding(left: 44, right: 44, bottom: 24)),
  ]) {
    testWidgets('rendered compact portrait fixture on $name', (tester) async {
      await pumpCompactEditor(tester, size: size, portrait: true, russian: true, padding: padding);
      await expectLater(find.byKey(const Key('compact-editor-screen')), matchesGoldenFile('goldens/compact_$name.png'));
      await tester.tap(find.byKey(const Key('editor-mode-draw')));
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const Key('compact-editor-screen')),
        matchesGoldenFile('goldens/compact_${name}_draw.png'),
      );
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }
}
