import 'package:crop_image/crop_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/presentation/pages/edit/annotation_canvas.dart';
import 'package:immich_mobile/presentation/pages/edit/edit.page.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/editor_chrome.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';

import 'editor_compact_layout_test.dart' show editorPhotoRect, pumpCompactEditor, selectEditorMode, tapEditorControl;
import 'editor_theme_test_host.dart';

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
}

void expectEditorTheme(WidgetTester tester, Brightness brightness) {
  final dock = find.byKey(const Key('editor-bottom-panel'));
  final colors = Theme.of(tester.element(dock)).colorScheme;
  expect(colors.brightness, brightness);
  final background = tester.widget<Material>(dock).color!;
  expect(background.a, closeTo(.94, .01));
  for (final photo in [Colors.white, Colors.black]) {
    final surface = Color.alphaBlend(background, photo);
    expect(_contrast(colors.onSurface, surface), greaterThanOrEqualTo(4.5));
    expect(_contrast(colors.primary, surface), greaterThanOrEqualTo(3));
    expect(_contrast(colors.error, surface), greaterThanOrEqualTo(3));
  }
  expect(_contrast(colors.primary, colors.primaryContainer), greaterThanOrEqualTo(3));
  final appBar = tester.widget<AppBar>(find.byType(AppBar));
  expect(appBar.backgroundColor, colors.surface);
  final system = appBar.systemOverlayStyle!;
  final icons = brightness == Brightness.dark ? Brightness.light : Brightness.dark;
  expect(system.statusBarIconBrightness, icons);
  expect(system.statusBarBrightness, brightness);
  expect(system.systemNavigationBarIconBrightness, icons);
  expect(system.systemNavigationBarColor, colors.surface);
  final chrome = find.descendant(
    of: find.byType(EditorChrome),
    matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
  );
  expect(tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(chrome.first).value, system);
  for (final key in ['editor-back', 'editor-header-undo', 'editor-header-redo', 'editor-save']) {
    final target = find.byKey(Key(key));
    expect(tester.getSize(target).shortestSide, greaterThanOrEqualTo(48));
    expect(find.descendant(of: target, matching: find.byType(FotoIcon)), findsOneWidget);
  }
  expect(tester.takeException(), isNull);
}

Future<Uint8List> _export(WidgetTester tester) async {
  final page = tester.widget<EditImagePage>(find.byType(EditImagePage));
  final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
  final state = container.read(editorStateProvider);
  return (await tester.runAsync(() async {
    final source = await EditedImageExporter.loadSource(page.image.image);
    try {
      final rendered = await EditedImageExporter.render(
        source: source,
        crop: state.crop,
        rotationDegrees: state.rotationAngle,
        flipHorizontal: state.flipHorizontal,
        flipVertical: state.flipVertical,
        annotations: state.annotations,
        straightenDegrees: state.straightenDegrees,
        adjustments: state.adjustments,
        selectedFilterIndex: state.selectedFilterIndex,
        filterIntensity: state.filterIntensity,
      );
      try {
        return await EditedImageExporter.encodePng(rendered);
      } finally {
        rendered.dispose();
      }
    } finally {
      source.dispose();
    }
  }))!;
}

void main() {
  setUpAll(() async {
    final font = FontLoader('GoogleSans');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      font.addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-$weight.ttf'));
    }
    await font.load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final mode in ThemeMode.values) {
    testWidgets('$mode respects the FOTO preference during live phone brightness changes', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await pumpCompactEditor(tester, themeMode: mode);
      final state = tester.state(find.byType(EditImagePage));
      final photo = editorPhotoRect(tester);
      final dock = tester.getRect(find.byKey(const Key('editor-bottom-panel')));
      for (final phone in [Brightness.light, Brightness.dark, Brightness.light]) {
        tester.platformDispatcher.platformBrightnessTestValue = phone;
        await tester.pumpAndSettle();
        expectEditorTheme(
          tester,
          mode == ThemeMode.system
              ? phone
              : mode == ThemeMode.dark
              ? Brightness.dark
              : Brightness.light,
        );
        expect(tester.state(find.byType(EditImagePage)), same(state));
        expect(editorPhotoRect(tester), photo);
        expect(tester.getRect(find.byKey(const Key('editor-bottom-panel'))), dock);
        expect(dock.height, 56 + 24);
      }
    });
  }

  testWidgets('live theme changes retain ink, selected tool, zoom/pan, crop, history and identical exported pixels', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpCompactEditor(tester, themeMode: ThemeMode.system, portrait: true);
    await selectEditorMode(tester, 'draw');
    await tapEditorControl(tester, 'editor-tool-highlighter');
    final canvas = find.byType(AnnotationCanvas);
    final center = tester.getCenter(canvas);
    await tester.dragFrom(center - const Offset(50, 20), const Offset(90, 45));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(canvas));
    expect(container.read(editorStateProvider).annotations, isNotEmpty);
    final one = await tester.startGesture(center - const Offset(30, 0), pointer: 1);
    final two = await tester.startGesture(center + const Offset(30, 0), pointer: 2);
    await one.moveTo(center - const Offset(65, 10));
    await two.moveTo(center + const Offset(90, 20));
    await one.up();
    await two.up();
    await tester.pumpAndSettle();
    final transform = tester.widget<Transform>(find.byKey(const Key('editor-zoom-transform'))).transform.clone();
    expect(transform.getMaxScaleOnAxis(), greaterThan(1));
    final crop = tester.widget<CropImage>(find.byType(CropImage)).controller;
    final before = container.read(editorStateProvider);
    final pixels = await _export(tester);
    final photo = editorPhotoRect(tester);
    await tapEditorControl(tester, 'editor-color');
    final popover = find.byKey(const Key('editor-parameter-popover'));
    expect(popover, findsOneWidget);
    final popoverRect = tester.getRect(popover);
    for (final phone in [Brightness.dark, Brightness.light]) {
      tester.platformDispatcher.platformBrightnessTestValue = phone;
      await tester.pumpAndSettle();
      expectEditorTheme(tester, phone);
      expect(Theme.of(tester.element(popover)).brightness, phone);
      expect(tester.getRect(popover), popoverRect);
      expect(tester.widget<AnnotationCanvas>(canvas).tool, AnnotationTool.highlighter);
      expect(container.read(editorStateProvider), before);
      expect(tester.widget<CropImage>(find.byType(CropImage)).controller, same(crop));
      expect(tester.widget<Transform>(find.byKey(const Key('editor-zoom-transform'))).transform, transform);
      expect(editorPhotoRect(tester), photo);
      expect(await _export(tester), orderedEquals(pixels));
    }
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    await tapEditorControl(tester, 'editor-header-undo');
    expect(container.read(editorStateProvider).annotations, isEmpty);
    expect(container.read(editorStateProvider).canRedo, isTrue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    await tapEditorControl(tester, 'editor-header-redo');
    expect(container.read(editorStateProvider).annotations, before.annotations);
    expect(await _export(tester), orderedEquals(pixels));
    // Explicit in-app choice changes the same route, then overrides the phone.
    container.read(editorTestThemeModeProvider.notifier).state = ThemeMode.light;
    await tester.pumpAndSettle();
    expectEditorTheme(tester, Brightness.light);
    expect(container.read(editorStateProvider).annotations, before.annotations);
  });

  testWidgets('paired review states retain identical image and dock geometry in both themes', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpCompactEditor(tester, themeMode: ThemeMode.system, russian: true, portrait: true);
    final baseline = editorPhotoRect(tester);
    final image = tester.getRect(find.byKey(const Key('editor-image-surface')));
    Future<void> capture(String state) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        await tester.pumpAndSettle();
        expectEditorTheme(tester, brightness);
        expect(editorPhotoRect(tester), baseline);
        expect(tester.getRect(find.byKey(const Key('editor-image-surface'))), image);
        final dock = tester.getRect(find.byKey(const Key('editor-bottom-panel')));
        expect(dock.height, 80);
        final name = 'theme_${brightness.name}_$state';
        debugPrint('EDITOR_VIEWPORT $name photo=$baseline image=$image dock=$dock');
        await expectLater(find.byType(Overlay), matchesGoldenFile('goldens/fixed_dock_$name.png'));
      }
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
