import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/pages/edit/annotation_canvas.dart';
import 'package:immich_mobile/presentation/pages/edit/edit.page.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';

import 'editor_compact_layout_test.dart' show editorPhotoRect, pumpCompactEditor, selectEditorMode, tapEditorControl;

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'icon-only FOTO header retains accessible Save Copy, Cancel and history on $platform',
      (tester) async {
        final semantics = tester.ensureSemantics();
        addTearDown(semantics.dispose);
        await pumpCompactEditor(tester, russian: true);
        expect(tester.widget<AppBar>(find.byType(AppBar)).actions, hasLength(3));
        for (final key in ['editor-back', 'editor-header-undo', 'editor-header-redo', 'editor-save']) {
          final target = find.byKey(Key(key));
          expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
          expect(find.descendant(of: target, matching: find.byType(FotoIcon)), findsOneWidget);
          expect(find.descendant(of: target, matching: find.byType(Text)), findsNothing);
        }
        expect(find.byTooltip('Сохранить копию'), findsOneWidget);
        expect(find.bySemanticsLabel('Сохранить копию'), findsOneWidget);
        expect(tester.widget<TextButton>(find.byKey(const Key('editor-save'))).onPressed, isNull);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('every category is accessible without captions or a second persistent row', (tester) async {
    await pumpCompactEditor(tester, size: const Size(320, 720), russian: true, scale: 2);
    final baseline = editorPhotoRect(tester);
    for (final mode in ['crop', 'draw', 'text', 'filters', 'adjustments', 'shapes', 'stickers']) {
      await selectEditorMode(tester, mode);
      expect(editorPhotoRect(tester), baseline);
      expect(find.byKey(const Key('editor-mode-bar')), findsNothing);
      expect(find.byKey(const Key('editor-tools-back')).hitTestable(), findsOneWidget);
      final dock = find.byKey(const Key('editor-fixed-dock'));
      expect(find.descendant(of: dock, matching: find.byType(Text)), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('contextual adjustment and sticker actions keep the original editor history', (tester) async {
    await pumpCompactEditor(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
    final photo = editorPhotoRect(tester);
    await selectEditorMode(tester, 'adjustments');
    await tapEditorControl(tester, 'editor-color-adjustments');
    final slider = find.byKey(const ValueKey('adjustment-slider-brightness'));
    await tester.ensureVisible(slider);
    await tester.drag(slider, const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(container.read(editorStateProvider).hasUnsavedEdits, isTrue);
    final adjustment = Map<String, double>.of(container.read(editorStateProvider).adjustments);
    await selectEditorMode(tester, 'stickers');
    await tapEditorControl(tester, 'editor-sticker-star');
    expect(container.read(editorStateProvider).annotations.single.text, 'star');
    expect(container.read(editorStateProvider).adjustments, adjustment);
    await tapEditorControl(tester, 'editor-header-undo');
    expect(container.read(editorStateProvider).annotations, isEmpty);
    expect(container.read(editorStateProvider).adjustments, adjustment);
    await tapEditorControl(tester, 'editor-header-redo');
    expect(container.read(editorStateProvider).annotations.single.text, 'star');
    expect(editorPhotoRect(tester), photo);
    expect(tester.takeException(), isNull);
  });

  testWidgets('text insertion uses the existing document and restores the viewport after IME', (tester) async {
    await pumpCompactEditor(
      tester,
      size: const Size(852, 393),
      padding: const FakeViewPadding(left: 44, right: 44, bottom: 24),
    );
    await selectEditorMode(tester, 'text');
    final baseline = editorPhotoRect(tester);
    final canvas = tester.getRect(find.byType(AnnotationCanvas));
    await tester.tapAt(canvas.topLeft + Offset(canvas.width * .25, canvas.height * .4));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('annotation-text-input')), 'FOTO');
    await tester.tap(find.byKey(const Key('annotation-text-confirm')));
    await tester.pumpAndSettle();
    expect(tester.widget<AnnotationCanvas>(find.byType(AnnotationCanvas)).editor.elements.single.text, 'FOTO');
    expect(editorPhotoRect(tester), baseline);
    expect(tester.takeException(), isNull);
  });
}
