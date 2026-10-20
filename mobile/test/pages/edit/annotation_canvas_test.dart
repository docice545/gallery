import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/presentation/pages/edit/annotation_canvas.dart';
import 'package:immich_mobile/utils/annotation_editor.dart';

void main() {
  testWidgets('normalizes stroke thickness against the image side', (tester) async {
    final first = AnnotationEditor();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: AnnotationCanvas(editor: first, tool: AnnotationTool.pen, color: Colors.red, width: 5, opacity: 1),
          ),
        ),
      ),
    );
    await tester.dragFrom(tester.getCenter(find.byType(AnnotationCanvas)), const Offset(40, 0));

    final second = AnnotationEditor();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 600,
            height: 400,
            child: AnnotationCanvas(editor: second, tool: AnnotationTool.pen, color: Colors.red, width: 5, opacity: 1),
          ),
        ),
      ),
    );
    await tester.dragFrom(tester.getCenter(find.byType(AnnotationCanvas)), const Offset(40, 0));

    expect(first.elements.single.width * 200, second.elements.single.width * 400);
  });

  testWidgets('draws a normalized stroke and supports tool changes', (tester) async {
    final editor = AnnotationEditor();
    const tool = AnnotationTool.pen;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: StatefulBuilder(
            builder: (context, setState) => AnnotationCanvas(
              editor: editor,
              tool: tool,
              color: Colors.red,
              width: 5,
              opacity: 1,
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
      ),
    );

    final canvas = find.byType(AnnotationCanvas);
    await tester.dragFrom(tester.getTopLeft(canvas) + const Offset(30, 40), const Offset(120, 80));
    expect(editor.elements, hasLength(1));
    expect(editor.elements.single.tool, AnnotationTool.pen);
    expect(editor.elements.single.points.first.dx, inInclusiveRange(0, 1));
    expect(editor.elements.single.points.last.dy, inInclusiveRange(0, 1));
  });

  testWidgets('eraser removes the topmost annotation under the gesture', (tester) async {
    final editor = AnnotationEditor()
      ..add(
        AnnotationElement(
          id: 'stroke',
          tool: AnnotationTool.pen,
          points: const [Offset(.2, .5), Offset(.8, .5)],
          color: Colors.red,
          width: 5,
          opacity: 1,
        ),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: AnnotationCanvas(editor: editor, tool: AnnotationTool.eraser, color: Colors.red, width: 5, opacity: 1),
        ),
      ),
    );

    final canvas = find.byType(AnnotationCanvas);
    await tester.tapAt(tester.getCenter(canvas));
    expect(editor.elements, isEmpty);
    expect(editor.undo(), isTrue);
    expect(editor.elements.single.id, 'stroke');
  });

  testWidgets('a second pointer cancels an in-progress stroke until both fingers lift', (tester) async {
    final editor = AnnotationEditor();
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AnnotationCanvas(
          editor: editor,
          tool: AnnotationTool.pen,
          color: Colors.red,
          width: 5,
          opacity: 1,
          onChanged: (_) => changes++,
        ),
      ),
    );
    final center = tester.getCenter(find.byType(AnnotationCanvas));
    final first = await tester.startGesture(center - const Offset(40, 0), pointer: 1);
    await first.moveBy(const Offset(30, 0));
    await tester.pump();
    final second = await tester.startGesture(center + const Offset(40, 0), pointer: 2);
    await first.moveBy(const Offset(-20, 0));
    await second.moveBy(const Offset(20, 0));
    await first.up();
    await second.moveBy(const Offset(30, 0));
    await second.up();
    await tester.pump();
    expect(editor.elements, isEmpty);
    expect(editor.canUndo, isFalse);
    expect(changes, 0);

    await tester.dragFrom(center, const Offset(60, 30));
    expect(editor.elements, hasLength(1));
    expect(changes, 1);
  });

  testWidgets('pointer cancellation discards the unfinished annotation', (tester) async {
    final editor = AnnotationEditor();
    await tester.pumpWidget(
      MaterialApp(
        home: AnnotationCanvas(editor: editor, tool: AnnotationTool.rectangle, color: Colors.red, width: 5, opacity: 1),
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(find.byType(AnnotationCanvas)));
    await gesture.moveBy(const Offset(60, 30));
    await gesture.cancel();
    await tester.pump();
    expect(editor.elements, isEmpty);
    expect(editor.canUndo, isFalse);
  });

  for (final tool in [AnnotationTool.eraser, AnnotationTool.move]) {
    testWidgets('adding a second finger cancels $tool without changing the document or undo history', (tester) async {
      final editor = AnnotationEditor()
        ..add(
          AnnotationElement(
            id: 'original',
            tool: AnnotationTool.rectangle,
            points: const [Offset(.2, .4), Offset(.8, .6)],
            color: Colors.red,
            width: 5,
            opacity: 1,
          ),
        );
      final original = editor.elements.single;
      await tester.pumpWidget(
        MaterialApp(
          home: AnnotationCanvas(editor: editor, tool: tool, color: Colors.red, width: 5, opacity: 1),
        ),
      );
      final center = tester.getCenter(find.byType(AnnotationCanvas));
      final first = await tester.startGesture(center, pointer: 1);
      await first.moveBy(const Offset(30, 0));
      final second = await tester.startGesture(center + const Offset(60, 0), pointer: 2);
      await first.moveBy(const Offset(-20, 0));
      await second.moveBy(const Offset(20, 0));
      await second.up();
      await first.up();
      await tester.pump();
      expect(editor.elements.single, original);
      // Undo must still undo the original addition, with no extra move/erase entry.
      expect(editor.undo(), isTrue);
      expect(editor.elements, isEmpty);
      expect(editor.undo(), isFalse);
    });
  }

  testWidgets('resizing during a single-finger stroke discards the unfinished stroke', (tester) async {
    final editor = AnnotationEditor();
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
                  tool: AnnotationTool.pen,
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
    final gesture = await tester.startGesture(tester.getCenter(find.byType(AnnotationCanvas)));
    await gesture.moveBy(const Offset(40, 0));
    resize(() => size = const Size(200, 300));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await gesture.up();
    expect(editor.elements, isEmpty);
    expect(editor.canUndo, isFalse);
    await tester.drag(find.byType(AnnotationCanvas), const Offset(40, 30));
    expect(editor.elements, hasLength(1));
  });

  testWidgets('eraser follows a drag across multiple geometries and records one undo snapshot', (tester) async {
    final editor = AnnotationEditor()
      ..add(
        AnnotationElement(
          id: 'line',
          tool: AnnotationTool.pen,
          points: const [Offset(.1, .5), Offset(.45, .5)],
          color: Colors.red,
          width: 5,
          opacity: 1,
        ),
      )
      ..add(
        AnnotationElement(
          id: 'rect',
          tool: AnnotationTool.rectangle,
          points: const [Offset(.55, .35), Offset(.85, .65)],
          color: Colors.blue,
          width: 5,
          opacity: 1,
        ),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: AnnotationCanvas(
            editor: editor,
            tool: AnnotationTool.eraser,
            color: Colors.white,
            width: 5,
            opacity: 1,
          ),
        ),
      ),
    );

    final canvas = find.byType(AnnotationCanvas);
    final box = tester.renderObject<RenderBox>(canvas);
    final topLeft = box.localToGlobal(Offset.zero);
    final gesture = await tester.startGesture(topLeft + Offset(box.size.width * .1, box.size.height * .5));
    await gesture.moveTo(topLeft + Offset(box.size.width * .5, box.size.height * .5));
    await gesture.moveTo(topLeft + Offset(box.size.width * .55, box.size.height * .35));
    await gesture.moveTo(topLeft + Offset(box.size.width * .85, box.size.height * .35));
    await gesture.moveTo(topLeft + Offset(box.size.width * .85, box.size.height * .5));
    await gesture.up();
    expect(editor.elements, isEmpty);
    expect(editor.undo(), isTrue);
    expect(editor.elements.map((element) => element.id), ['line', 'rect']);
    expect(editor.undo(), isTrue);
    expect(editor.elements.single.id, 'line');
    expect(editor.undo(), isTrue);
    expect(editor.elements, isEmpty);
  });
}
