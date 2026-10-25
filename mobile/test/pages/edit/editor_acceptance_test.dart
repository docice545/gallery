import 'package:crop_image/crop_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/pages/edit/annotation_canvas.dart';
import 'package:immich_mobile/presentation/pages/edit/edit.page.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/repositories/magic_eraser.repository.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/editor_raster.dart';
import '../../test_utils.dart';
import '../../widget_tester_extensions.dart';

class _Capabilities extends Mock implements MagicEraserRepository {}

const _screen = Key('editor-acceptance-screen');
const _pill = Key('editor-drawing-pill');

Future<void> _pumpEditor(
  WidgetTester tester, {
  Size size = const Size(393, 852),
  FakeViewPadding insets = const FakeViewPadding(top: 28, bottom: 24),
  double textScale = 1,
}) async {
  TestUtils.init();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = insets;
  tester.view.viewPadding = insets;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  final source = (await tester.runAsync(createEditorRaster))!;
  addTearDown(source.dispose);
  final png = (await tester.runAsync(() => EditedImageExporter.encodePng(source)))!;
  final repository = _Capabilities();
  when(() => repository.isEnabled(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((_) async => true);
  await tester.runAsync(
    () => tester.pumpConsumerWidgetRaw(
      RepaintBoundary(
        key: _screen,
        child: EditImagePage(
          image: Image.memory(png),
          asset: TestUtils.createRemoteAsset(id: 'acceptance-only', width: 64, height: 48),
          applyEdits: (_) => Future.error(StateError('Acceptance must never replace an original')),
        ),
      ),
      overrides: [
        magicEraserRepositoryProvider.overrideWithValue(repository),
        immichThemeProvider.overrideWith(
          (ref) => ImmichTheme(
            light: ColorScheme.fromSeed(seedColor: Colors.blue),
            dark: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
          ),
        ),
      ],
    ),
  );
  for (var attempt = 0; attempt < 100 && find.byType(CropImage).evaluate().isEmpty; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(find.byType(CropImage), findsOneWidget);
  await EasyLocalization.of(tester.element(find.byType(EditImagePage)))!.setLocale(const Locale('ru'));
  await tester.pumpAndSettle();
}

Future<void> _mode(WidgetTester tester, String mode) async {
  final button = find.byKey(Key('editor-mode-$mode'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void _inside(Rect outer, Rect inner, String reason) {
  expect(inner.left, greaterThanOrEqualTo(outer.left - .01), reason: reason);
  expect(inner.top, greaterThanOrEqualTo(outer.top - .01), reason: reason);
  expect(inner.right, lessThanOrEqualTo(outer.right + .01), reason: reason);
  expect(inner.bottom, lessThanOrEqualTo(outer.bottom + .01), reason: reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Existing project fonts, not downloaded resources. Real glyphs make visual
    // review useful; the default test font would turn Russian labels into boxes.
    final text = FontLoader('GoogleSans');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      text.addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-$weight.ttf'));
    }
    await text.load();
    // The caption's generic family normally comes from the device. Pin an
    // existing project font in goldens instead of the test engine's Ahem boxes.
    await (FontLoader('sans-serif')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('acceptance: black screen and back, history and Russian Save with vertical dots on $platform', (
      tester,
    ) async {
      await _pumpEditor(tester);
      final page = find.byType(EditImagePage);
      final scaffold = tester.widget<Scaffold>(find.descendant(of: page, matching: find.byType(Scaffold)));
      expect(scaffold.backgroundColor, Colors.black);
      expect(tester.widget<AppBar>(find.byType(AppBar)).backgroundColor, Colors.black);
      expect(Theme.of(tester.element(find.byKey(const Key('editor-back')))).brightness, Brightness.dark);
      final reset = find.byKey(const Key('editor-back'));
      final save = find.byKey(const Key('editor-save'));
      final more = find.byKey(const Key('editor-more'));
      expect(find.descendant(of: reset, matching: find.byIcon(Icons.arrow_back)), findsOneWidget);
      expect(find.byKey(const Key('editor-header-undo')), findsOneWidget);
      expect(find.byKey(const Key('editor-header-redo')), findsOneWidget);
      expect(find.descendant(of: save, matching: find.text('Сохранить\nкопию')), findsOneWidget);
      expect(find.descendant(of: more, matching: find.byIcon(Icons.more_vert)), findsOneWidget);
      expect(tester.getCenter(reset).dx, lessThan(tester.getCenter(save).dx));
      expect(tester.getCenter(save).dx, lessThan(tester.getCenter(more).dx));
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets('acceptance: all five primary sections are visible together with short Russian labels', (tester) async {
    await _pumpEditor(tester);
    final bar = find.byKey(const Key('editor-mode-bar'));
    final labels = tester.widgetList<Text>(find.descendant(of: bar, matching: find.byType(Text))).toList();
    for (final text in find.descendant(of: bar, matching: find.byType(Text)).evaluate()) {
      expect(
        (text.findRenderObject()! as RenderParagraph).didExceedMaxLines,
        isFalse,
        reason: 'Primary labels must fit without scrolling: ${(text.widget as Text).data}',
      );
    }
    expect(labels.map((label) => label.data), ['Обрезать', 'Фильтры', 'Рисование', 'Текст', 'Стикеры']);
  });

  testWidgets('acceptance: yellow modes, blue/purple ink and circular ordered pill with separate history', (
    tester,
  ) async {
    await _pumpEditor(tester);
    await _mode(tester, 'draw');
    final pill = find.byKey(_pill);
    final buttons = tester
        .widgetList<IconButton>(find.descendant(of: pill, matching: find.byType(IconButton)))
        .toList();
    expect(buttons.map((button) => (button.key! as ValueKey<String>).value), [
      'editor-tool-pen',
      'editor-tool-highlighter',
      'editor-tool-brush',
      'editor-tool-eraser',
      'editor-toggle-settings',
    ]);
    expect((buttons.first.icon as Icon).color, Colors.blue);
    expect((buttons[1].icon as Icon).color, Colors.purple);
    expect(buttons.first.isSelected, isTrue);
    expect(buttons.first.style!.shape!.resolve({WidgetState.selected}), isA<CircleBorder>());
    expect(buttons.first.style!.backgroundColor!.resolve({WidgetState.selected}), const Color(0xff5a5122));
    final divider = find.descendant(of: pill, matching: find.byType(VerticalDivider));
    expect(divider, findsOneWidget);
    expect(
      tester.getCenter(divider).dx,
      greaterThan(tester.getRect(find.byKey(const Key('editor-tool-eraser'))).right),
    );
    expect(
      tester.getCenter(divider).dx,
      lessThan(tester.getRect(find.byKey(const Key('editor-toggle-settings'))).left),
    );
    expect(
      tester.getRect(pill).bottom,
      lessThanOrEqualTo(tester.getRect(find.byKey(const Key('editor-mode-bar'))).top),
    );
    final decoration = tester.widget<DecoratedBox>(pill).decoration as BoxDecoration;
    expect(decoration.color, const Color(0xff303030));
    expect(decoration.borderRadius, BorderRadius.circular(32));
    for (final (mode, label) in [('draw', 'Рисование'), ('stickers', 'Стикеры'), ('text', 'Текст')]) {
      await _mode(tester, mode);
      final button = find.byKey(Key('editor-mode-$mode'));
      expect(find.descendant(of: button, matching: find.text(label)), findsOneWidget);
      expect(tester.widget<TextButton>(button).style!.foregroundColor!.resolve({}), Colors.yellow);
    }
    expect(tester.takeException(), isNull);
  });

  for (final (name, size, insets, scale) in [
    ('portrait cutouts', const Size(393, 852), const FakeViewPadding(top: 28, bottom: 24), 1.0),
    ('landscape cutouts', const Size(852, 393), const FakeViewPadding(left: 44, right: 44, bottom: 24), 1.0),
    ('compact landscape large text', const Size(720, 320), const FakeViewPadding(left: 24, right: 24, bottom: 24), 2.0),
    ('compact portrait large text', const Size(320, 720), const FakeViewPadding(top: 24, bottom: 24), 2.0),
  ]) {
    testWidgets('acceptance: $name keeps complete controls outside system insets', (tester) async {
      await _pumpEditor(tester, size: size, insets: insets, textScale: scale);
      final safe = Rect.fromLTRB(insets.left, insets.top, size.width - insets.right, size.height - insets.bottom);
      for (final key in ['editor-back', 'editor-header-undo', 'editor-header-redo', 'editor-save', 'editor-more']) {
        final button = find.byKey(Key(key));
        _inside(safe, tester.getRect(button), key);
        for (final text in find.descendant(of: button, matching: find.byType(Text)).evaluate()) {
          final paragraph = text.findRenderObject()! as RenderParagraph;
          final transform = paragraph.getTransformTo(null);
          _inside(
            tester.getRect(button),
            MatrixUtils.transformRect(transform, Offset.zero & paragraph.size),
            '$key rendered caption must remain inside its touch target',
          );
          final scaledFont =
              MediaQuery.textScalerOf(text).scale(paragraph.text.style!.fontSize!) * transform.getMaxScaleOnAxis();
          expect(scaledFont, greaterThanOrEqualTo(14), reason: '$key must not fit by becoming illegibly small');
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason:
                '$key must keep its actual caption legible: ${tester.getSize(button)} / ${paragraph.size} / ${paragraph.text.style}',
          );
        }
      }
      expect(
        tester.getRect(find.byKey(const Key('editor-back'))).right,
        lessThanOrEqualTo(tester.getRect(find.byKey(const Key('editor-save'))).left),
      );
      await _mode(tester, 'draw');
      final settings = find.byKey(_pill);
      for (final key in [
        'editor-tool-pen',
        'editor-tool-highlighter',
        'editor-tool-brush',
        'editor-tool-eraser',
        'editor-toggle-settings',
      ]) {
        final button = find.byKey(Key(key));
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        final rect = tester.getRect(button);
        _inside(safe, rect, key);
        _inside(tester.getRect(settings), rect, '$key must fit the visible settings viewport');
        expect(rect.shortestSide, greaterThanOrEqualTo(48), reason: key);
      }
      final viewport = tester.getRect(find.byKey(const Key('editor-preview-viewport')));
      expect(viewport.height, greaterThan(0));
      final image = tester.getRect(find.byKey(const Key('editor-image-surface')));
      final fitted = applyBoxFit(BoxFit.contain, const Size(64, 48), viewport.size).destination;
      expect(image.width, closeTo(fitted.width, .01));
      expect(image.height, closeTo(fitted.height, .01));
      expect((image.center - viewport.center).distance, lessThan(.01));
      expect(tester.widget<AnnotationCanvas>(find.byType(AnnotationCanvas)).editor.elements, isEmpty);
      if (name == 'compact landscape large text') {
        await expectLater(find.byKey(_screen), matchesGoldenFile('goldens/editor_ru_compact_large_text.png'));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('visual acceptance: Russian drawing screen with source pixels and a new stroke', (tester) async {
    await _pumpEditor(tester);
    await _mode(tester, 'draw');
    final canvas = tester.getRect(find.byType(AnnotationCanvas));
    await tester.dragFrom(
      canvas.topLeft + Offset(canvas.width * .2, canvas.height * .3),
      Offset(canvas.width * .5, canvas.height * .2),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<AnnotationCanvas>(find.byType(AnnotationCanvas)).editor.elements, hasLength(1));
    await expectLater(find.byKey(_screen), matchesGoldenFile('goldens/editor_ru_draw_portrait.png'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('visual acceptance: Russian landscape text editor with system cutouts', (tester) async {
    await _pumpEditor(
      tester,
      size: const Size(852, 393),
      insets: const FakeViewPadding(left: 44, right: 44, bottom: 24),
    );
    await _mode(tester, 'text');
    final canvas = tester.getRect(find.byType(AnnotationCanvas));
    await tester.tapAt(canvas.topLeft + Offset(canvas.width * .25, canvas.height * .4));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('annotation-text-input')), 'FOTO');
    await tester.tap(find.byKey(const Key('annotation-text-confirm')));
    await tester.pumpAndSettle();
    expect(tester.widget<AnnotationCanvas>(find.byType(AnnotationCanvas)).editor.elements.single.text, 'FOTO');
    await expectLater(find.byKey(_screen), matchesGoldenFile('goldens/editor_ru_text_landscape.png'));
    expect(tester.takeException(), isNull);
  });
}
