import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/presentation/pages/edit/annotation_canvas.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_viewport.dart';
import 'package:immich_mobile/utils/annotation_editor.dart';
import 'package:immich_mobile/utils/annotation_painter.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';

AnnotationElement _sticker({double rotation = 0, double scale = 1}) => AnnotationElement(
  id: 'sticker',
  tool: AnnotationTool.sticker,
  points: const [Offset(.25, .25)],
  color: Colors.yellow,
  width: 1,
  opacity: .8,
  text: 'star',
  fontSize: .3,
  rotation: rotation,
  scale: scale,
);

void main() {
  test('pixel-space object transforms invert exactly on a non-square source', () {
    final object = _sticker(rotation: math.pi / 3, scale: 1.7);
    const point = Offset(130, 140);
    const size = Size(300, 200);
    expect(
      (object.transformPoint(object.transformPoint(point, size), size, inverse: true) - point).distance,
      lessThan(1e-9),
    );
    expect(annotationBounds(object, size).width, greaterThan(60));
  });

  test('style, transform and reorder remain immutable and undoable', () {
    final object = _sticker();
    final text = AnnotationElement(
      id: 'text',
      tool: AnnotationTool.text,
      points: const [Offset(.2, .2)],
      color: Colors.red,
      width: 1,
      opacity: 1,
      text: 'FOTO',
    );
    final editor = AnnotationEditor()
      ..add(object)
      ..add(text);
    final changed = text.copyWith(
      fontFamily: 'serif',
      fontSize: .1,
      outlineWidth: .005,
      backgroundColor: Colors.black,
      rotation: .5,
      scale: 1.3,
    );
    editor.update(changed);
    expect(editor.elements.last, changed);
    expect(text.rotation, 0);
    editor.reorder(text.id, 0);
    expect(editor.elements.first, changed);
    editor.undo();
    expect(editor.elements.last, changed);
    editor.undo();
    expect(editor.elements.last, text);
  });

  Future<void> pumpSurface(
    WidgetTester tester,
    AnnotationEditor editor, {
    AnnotationTool tool = AnnotationTool.move,
    String? selectedId,
    ValueNotifier<bool>? objectActive,
    ValueNotifier<bool>? navigation,
    ValueChanged<String?>? onSelection,
    ValueChanged<List<AnnotationElement>>? onChanged,
    bool showSelection = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: EditorViewport(
              contentSize: const Size(300, 200),
              navigationActive: navigation ?? ValueNotifier(false),
              objectTransformActive: objectActive,
              child: SizedBox(
                width: 300,
                height: 200,
                child: AnnotationCanvas(
                  editor: editor,
                  selectedId: selectedId,
                  tool: tool,
                  color: Colors.blue,
                  width: 4,
                  opacity: 1,
                  objectTransformActive: objectActive,
                  navigationActive: navigation,
                  onSelectionChanged: onSelection,
                  onChanged: onChanged,
                  showSelection: showSelection,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('two-finger object move/scale/rotate commits once without zooming the photo or resuming a stroke', (
    tester,
  ) async {
    final editor = AnnotationEditor()..add(_sticker());
    final active = ValueNotifier(false);
    final navigation = ValueNotifier(false);
    addTearDown(active.dispose);
    addTearDown(navigation.dispose);
    var commits = 0;
    await pumpSurface(
      tester,
      editor,
      selectedId: 'sticker',
      objectActive: active,
      navigation: navigation,
      onChanged: (_) => commits++,
    );
    final origin = tester.getTopLeft(find.byType(AnnotationCanvas));
    final first = await tester.startGesture(origin + const Offset(90, 65), pointer: 1);
    final second = await tester.startGesture(origin + const Offset(115, 65), pointer: 2);
    await second.moveTo(origin + const Offset(90, 115));
    await tester.pump();
    expect(active.value, isTrue);
    expect(navigation.value, isFalse);
    await second.up();
    await first.moveBy(const Offset(20, 0));
    await first.up();
    await tester.pump();
    expect(commits, 1);
    expect(editor.elements.single.scale, closeTo(2, .001));
    expect(editor.elements.single.rotation, closeTo(math.pi / 2, .001));
    expect(active.value, isFalse);
    expect(navigation.value, isFalse);
    final transform = tester.widget<Transform>(find.byKey(const Key('editor-zoom-transform'))).transform;
    expect(transform.getMaxScaleOnAxis(), 1);
    expect(editor.undo(), isTrue);
    expect(editor.elements.single, _sticker());
  });

  testWidgets('pointer cancellation discards the object draft and permits a clean retry', (tester) async {
    final editor = AnnotationEditor()..add(_sticker());
    final active = ValueNotifier(false);
    addTearDown(active.dispose);
    await pumpSurface(tester, editor, selectedId: 'sticker', objectActive: active);
    final origin = tester.getTopLeft(find.byType(AnnotationCanvas));
    final first = await tester.startGesture(origin + const Offset(90, 65), pointer: 1);
    final second = await tester.startGesture(origin + const Offset(115, 65), pointer: 2);
    await second.moveBy(const Offset(30, 20));
    await second.cancel();
    await first.up();
    await tester.pump();
    expect(editor.elements.single, _sticker());
    expect(active.value, isFalse);
    final retry = await tester.startGesture(origin + const Offset(90, 65), pointer: 3);
    final next = await tester.startGesture(origin + const Offset(115, 65), pointer: 4);
    await next.moveBy(const Offset(25, 0));
    await next.up();
    await retry.up();
    await tester.pump();
    expect(editor.elements.single.scale, greaterThan(1));
  });

  testWidgets('rotated scaled sticker is selectable through its inverse source transform', (tester) async {
    final object = _sticker(rotation: math.pi / 4, scale: 1.5);
    final editor = AnnotationEditor()..add(object);
    String? selected;
    await pumpSurface(tester, editor, onSelection: (id) => selected = id);
    final local = object.transformPoint(const Offset(100, 80), const Size(300, 200));
    await tester.tapAt(tester.getTopLeft(find.byType(AnnotationCanvas)) + local);
    expect(selected, object.id);
  });

  testWidgets('stroke eraser removes only ink under overlapping text and sticker layers', (tester) async {
    final stroke = AnnotationElement(
      id: 'ink',
      tool: AnnotationTool.pen,
      points: const [Offset(.2, .4), Offset(.8, .4)],
      color: Colors.red,
      width: 5,
      opacity: 1,
    );
    final text = AnnotationElement(
      id: 'text',
      tool: AnnotationTool.text,
      points: const [Offset(.3, .3)],
      color: Colors.white,
      width: 1,
      opacity: 1,
      text: 'caption',
      fontSize: .12,
    );
    final editor = AnnotationEditor()
      ..add(stroke)
      ..add(text)
      ..add(_sticker());
    await pumpSurface(tester, editor, tool: AnnotationTool.eraser);
    await tester.tapAt(tester.getTopLeft(find.byType(AnnotationCanvas)) + const Offset(105, 80));
    expect(editor.elements.map((e) => e.id), ['text', 'sticker']);
    editor.undo();
    expect(editor.elements, [stroke, text, _sticker()]);
  });

  for (final tool in ['text', 'star', 'heart', 'smile', '🙂']) {
    testWidgets('styled $tool object renders identically in the real canvas and exported PNG', (tester) async {
      final object = tool == 'text'
          ? AnnotationElement(
              id: 'caption',
              tool: AnnotationTool.text,
              points: const [Offset(.15, .2)],
              color: Colors.red,
              width: 1,
              opacity: .7,
              text: 'FOTO',
              fontFamily: 'serif',
              fontSize: .14,
              outlineWidth: .008,
              backgroundColor: Colors.black,
              scale: 1.2,
              rotation: .25,
            )
          : _sticker(rotation: .25, scale: 1.2).copyWith(text: tool);
      final editor = AnnotationEditor()..add(object);
      final boundary = GlobalKey();
      ui.Image? source;
      ui.Image? preview;
      ui.Image? output;
      try {
        source = await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(Colors.white, BlendMode.src);
          final picture = recorder.endRecording();
          try {
            return await picture.toImage(300, 200);
          } finally {
            picture.dispose();
          }
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: boundary,
                child: SizedBox(
                  width: 300,
                  height: 200,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RawImage(image: source),
                      AnnotationCanvas(
                        editor: editor,
                        tool: AnnotationTool.move,
                        color: Colors.red,
                        width: 1,
                        opacity: 1,
                        showSelection: false,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final rendered = await tester.runAsync(() async {
          preview = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
          output = await EditedImageExporter.render(
            source: source!,
            crop: const Rect.fromLTWH(0, 0, 1, 1),
            rotationDegrees: 0,
            flipHorizontal: false,
            flipVertical: false,
            annotations: editor.elements,
          );
          return (await preview!.toByteData(), await output!.toByteData(), await source!.toByteData());
        });
        expect(rendered!.$1!.buffer.asUint8List(), rendered.$2!.buffer.asUint8List());
        expect(rendered.$2!.buffer.asUint8List(), isNot(rendered.$3!.buffer.asUint8List()));
      } finally {
        await tester.pumpWidget(const SizedBox());
        preview?.dispose();
        output?.dispose();
        source?.dispose();
      }
    });
  }
}
