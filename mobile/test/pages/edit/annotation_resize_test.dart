import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/presentation/pages/edit/annotation_canvas.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_viewport.dart';
import 'package:immich_mobile/utils/annotation_editor.dart';

void main() {
  final canvas = find.byType(AnnotationCanvas);
  final handle = find.byKey(const Key('annotation-resize-handle'));
  final selection = find.byKey(const Key('annotation-selection'));

  AnnotationElement element(AnnotationTool tool, {bool reversed = false, String? text}) => AnnotationElement(
    id: 'original',
    tool: tool,
    points: tool == AnnotationTool.text
        ? const [Offset(.05, .1)]
        : reversed
        ? const [Offset(.7, .7), Offset(.3, .3)]
        : const [Offset(.25, .25), Offset(.6, .55)],
    color: Colors.red,
    width: 5,
    opacity: 1,
    text: text,
  );

  Offset imagePoint(WidgetTester tester, Offset point) {
    final box = tester.renderObject<RenderBox>(canvas);
    return box.localToGlobal(Offset(point.dx * box.size.width, point.dy * box.size.height));
  }

  Future<void> pumpCanvas(
    WidgetTester tester,
    AnnotationEditor editor, {
    VoidCallback? onChanged,
    bool showSelection = true,
    Size size = const Size(300, 200),
  }) => tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox.fromSize(
          size: size,
          child: AnnotationCanvas(
            editor: editor,
            tool: AnnotationTool.move,
            color: Colors.red,
            width: 5,
            opacity: 1,
            showSelection: showSelection,
            onChanged: (_) => onChanged?.call(),
          ),
        ),
      ),
    ),
  );

  for (final tool in [AnnotationTool.rectangle, AnnotationTool.ellipse, AnnotationTool.arrow, AnnotationTool.text]) {
    for (final corner in [const Offset(.01, .01), const Offset(.99, .99)]) {
      testWidgets('$tool keeps its size and visible bounds when moved to $corner', (tester) async {
        final original = element(tool, text: 'A caption\non two lines');
        final editor = AnnotationEditor()..add(original);
        var changes = 0;
        await pumpCanvas(tester, editor, onChanged: () => changes++);
        final hit = tool == AnnotationTool.ellipse
            ? const Offset(.425, .25)
            : original.points.first + const Offset(.01, .01);
        await tester.tapAt(imagePoint(tester, hit));
        await tester.pump();
        final before = tester.getRect(selection);
        await tester.dragFrom(imagePoint(tester, hit), imagePoint(tester, corner) - imagePoint(tester, hit));
        await tester.pump();
        final moved = editor.elements.single;
        final after = tester.getRect(selection);
        final imageRect = tester.getRect(canvas);
        expect(after.width, closeTo(before.width, .001));
        expect(after.height, closeTo(before.height, .001));
        expect(after.left, greaterThanOrEqualTo(imageRect.left - .001));
        expect(after.top, greaterThanOrEqualTo(imageRect.top - .001));
        expect(after.right, lessThanOrEqualTo(imageRect.right + .001));
        expect(after.bottom, lessThanOrEqualTo(imageRect.bottom + .001));
        expect(moved.fontSize, original.fontSize);
        expect(moved, original.copyWith(points: moved.points));
        expect(changes, 1);
        expect(editor.undo(), isTrue);
        expect(editor.elements.single, original);
        expect(editor.redo(), isTrue);
        expect(editor.elements.single, moved);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final tool in [AnnotationTool.rectangle, AnnotationTool.ellipse, AnnotationTool.arrow]) {
    testWidgets('$tool resizes about its first point and commits one undo entry', (tester) async {
      final original = element(tool);
      final editor = AnnotationEditor()..add(original);
      var changes = 0;
      await pumpCanvas(tester, editor, onChanged: () => changes++);
      // The corner of an ellipse's bounding box is outside its outline.
      final hit = tool == AnnotationTool.ellipse ? const Offset(.425, .25) : original.points.first;
      await tester.tapAt(imagePoint(tester, hit));
      await tester.pump();
      expect(handle, findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveTo(imagePoint(tester, const Offset(.7, .7)));
      await gesture.moveTo(imagePoint(tester, const Offset(.8, .8)));
      await tester.pump();
      expect(editor.elements.single, original);
      expect(changes, 0);
      await gesture.up();
      await tester.pump();
      final resized = editor.elements.single;
      expect(resized.points.first, original.points.first);
      expect(resized.points.last.dx, closeTo(.8, .001));
      expect(resized.points.last.dy, closeTo(.8, .001));
      expect(changes, 1);
      expect(editor.undo(), isTrue);
      expect(editor.elements.single, original);
      expect(editor.redo(), isTrue);
      expect(editor.elements.single, resized);
      expect(editor.undo(), isTrue);
      expect(editor.undo(), isTrue);
      expect(editor.elements, isEmpty);
      expect(editor.undo(), isFalse);
    });
  }

  testWidgets('a reversed arrow keeps its first endpoint fixed when resizing', (tester) async {
    final original = element(AnnotationTool.arrow, reversed: true);
    final editor = AnnotationEditor()..add(original);
    await pumpCanvas(tester, editor);
    await tester.tapAt(imagePoint(tester, original.points.first));
    await tester.pump();
    expect(tester.getCenter(handle), imagePoint(tester, original.points.last));
    await tester.dragFrom(tester.getCenter(handle), const Offset(-30, -20));
    expect(editor.elements.single.points.first, original.points.first);
    expect(editor.elements.single.points.last.dx, closeTo(.2, .001));
    expect(editor.elements.single.points.last.dy, closeTo(.2, .001));
  });

  for (final caption in ['Foto', 'A long caption that wraps across several lines']) {
    testWidgets('text "$caption" shares bounds with selection and scales without moving its anchor', (tester) async {
      final original = element(AnnotationTool.text, text: caption);
      final editor = AnnotationEditor()..add(original);
      var changes = 0;
      await pumpCanvas(tester, editor, onChanged: () => changes++);
      final anchor = imagePoint(tester, original.points.first);
      await tester.tapAt(anchor + const Offset(4, 4));
      await tester.pump();
      final before = tester.getRect(selection);
      expect(before.topLeft, anchor);
      expect(tester.getCenter(handle), before.bottomRight);
      final scale = caption == 'Foto' ? 1.5 : 1.1;
      final diagonal = before.bottomRight - anchor;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveTo(anchor + diagonal * scale);
      await tester.pump();
      expect(editor.elements.single, original);
      await gesture.up();
      await tester.pump();
      expect(editor.elements.single.fontSize, closeTo(original.fontSize * scale, .0001));
      expect(editor.elements.single.points, original.points);
      final after = tester.getRect(selection);
      expect(after.topLeft, before.topLeft);
      expect(after.width, closeTo(before.width * scale, .1));
      // Text layout rounds each line's height to logical pixels.
      expect(after.height, closeTo(before.height * scale, 1));
      expect(changes, 1);
      expect(editor.undo(), isTrue);
      expect(editor.elements.single, original);
      expect(editor.undo(), isTrue);
      expect(editor.elements, isEmpty);
    });
  }

  testWidgets('capture hides selection; a surface resize preserves resized text coordinates and font size', (
    tester,
  ) async {
    final original = element(AnnotationTool.text, text: 'Foto');
    final editor = AnnotationEditor()..add(original);
    await pumpCanvas(tester, editor);
    await tester.tapAt(imagePoint(tester, original.points.first) + const Offset(4, 4));
    await tester.pump();
    await tester.dragFrom(tester.getCenter(handle), const Offset(24, 6));
    await tester.pump();
    final resized = editor.elements.single;
    final bounds = tester.getRect(selection);
    await pumpCanvas(tester, editor, showSelection: false);
    expect(selection, findsNothing);
    expect(handle, findsNothing);
    expect(editor.elements.single, resized);
    await pumpCanvas(tester, editor, size: const Size(150, 100));
    expect(editor.elements.single, resized);
    expect(tester.getRect(selection).width, closeTo(bounds.width / 2, .1));
    expect(tester.getRect(selection).height, closeTo(bounds.height / 2, 1));
    expect(editor.undo(), isTrue);
    expect(editor.elements.single, original);
    await pumpCanvas(tester, editor);
    expect(editor.undo(), isTrue);
    await pumpCanvas(tester, editor);
    expect(handle, findsNothing);
  });

  for (final interruption in ['cancel', 'second pointer', 'surface resize']) {
    testWidgets('$interruption discards resize without changing the document or history', (tester) async {
      final original = element(AnnotationTool.rectangle);
      final editor = AnnotationEditor()..add(original);
      var size = const Size(300, 200);
      late StateSetter resize;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                resize = setState;
                return SizedBox.fromSize(
                  size: size,
                  child: AnnotationCanvas(
                    editor: editor,
                    tool: AnnotationTool.move,
                    color: Colors.red,
                    width: 5,
                    opacity: 1,
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tapAt(imagePoint(tester, original.points.first));
      await tester.pump();
      final gesture = await tester.startGesture(tester.getCenter(handle), pointer: 1);
      await gesture.moveTo(imagePoint(tester, const Offset(.8, .8)));
      await tester.pump();
      if (interruption == 'cancel') {
        await gesture.cancel();
      } else if (interruption == 'second pointer') {
        final second = await tester.startGesture(imagePoint(tester, const Offset(.2, .8)), pointer: 2);
        await second.moveBy(const Offset(20, 0));
        await gesture.up();
        await second.up();
      } else {
        resize(() => size = const Size(200, 300));
        await tester.pump();
        await gesture.up();
      }
      await tester.pump();
      expect(editor.elements.single, original);
      expect(editor.undo(), isTrue);
      expect(editor.elements, isEmpty);
      expect(editor.undo(), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final tool in [AnnotationTool.rectangle, AnnotationTool.text]) {
    testWidgets('$tool move and resize use image coordinates after pinch, rotation and reflection', (tester) async {
      final original = element(
        tool,
        text: 'Foto',
      ).copyWith(points: tool == AnnotationTool.text ? const [Offset(.4, .4)] : const [Offset(.4, .4), Offset(.6, .6)]);
      final editor = AnnotationEditor()..add(original);
      final navigation = ValueNotifier(false);
      addTearDown(navigation.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: EditorViewport(
                contentSize: const Size(200, 300),
                navigationActive: navigation,
                child: RotatedBox(
                  quarterTurns: -1,
                  child: Transform.flip(
                    flipX: true,
                    child: SizedBox(
                      width: 300,
                      height: 200,
                      child: AnnotationCanvas(
                        editor: editor,
                        tool: AnnotationTool.move,
                        color: Colors.red,
                        width: 5,
                        opacity: 1,
                        navigationActive: navigation,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final center = tester.getCenter(find.byType(EditorViewport));
      final first = await tester.startGesture(center - const Offset(40, 0), pointer: 1);
      final second = await tester.startGesture(center + const Offset(40, 0), pointer: 2);
      await first.moveTo(center - const Offset(80, 0));
      await second.moveTo(center + const Offset(80, 0));
      await first.up();
      await second.up();
      await tester.pump();
      expect(tester.widget<Transform>(find.byKey(const Key('editor-zoom-transform'))).transform.getMaxScaleOnAxis(), 2);

      final start = imagePoint(tester, const Offset(.4, .4));
      await tester.dragFrom(start, imagePoint(tester, const Offset(.45, .45)) - start);
      await tester.pump();
      final moved = editor.elements.single;
      expect(moved.points.first.dx, closeTo(.45, .001));
      expect(moved.points.first.dy, closeTo(.45, .001));
      if (tool != AnnotationTool.text) {
        expect(moved.points.last.dx, closeTo(.65, .001));
        expect(moved.points.last.dy, closeTo(.65, .001));
      }

      final resizeStart = tester.getCenter(handle);
      final anchor = imagePoint(tester, moved.points.first);
      final target = tool == AnnotationTool.text
          ? anchor + (resizeStart - anchor) * 1.8
          : imagePoint(tester, const Offset(.7, .75));
      await tester.dragFrom(resizeStart, target - resizeStart);
      await tester.pump();
      expect(editor.elements.single.points.first, moved.points.first);
      if (tool == AnnotationTool.text) {
        expect(editor.elements.single.fontSize, closeTo(original.fontSize * 1.8, .0001));
      } else {
        expect(editor.elements.single.points.last.dx, closeTo(.7, .001));
        expect(editor.elements.single.points.last.dy, closeTo(.75, .001));
      }
      expect(editor.undo(), isTrue);
      expect(editor.elements.single, moved);
      expect(editor.undo(), isTrue);
      expect(editor.elements.single, original);
      expect(tester.takeException(), isNull);
    });
  }
}
