import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/presentation/pages/edit/annotation_canvas.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_viewport.dart';
import 'package:immich_mobile/utils/annotation_editor.dart';
import 'package:immich_mobile/utils/annotation_painter.dart';

void main() {
  final canvas = find.byType(AnnotationCanvas);
  AnnotationElement element(String id, AnnotationTool tool, List<Offset> points, {double width = 5, String? text}) =>
      AnnotationElement(id: id, tool: tool, points: points, color: Colors.red, width: width, opacity: 1, text: text);

  Offset imagePoint(WidgetTester tester, Offset point) {
    final box = tester.renderObject<RenderBox>(canvas);
    return box.localToGlobal(point * box.size.width);
  }

  Future<void> pumpCanvas(WidgetTester tester, AnnotationEditor editor) => tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox.square(
          dimension: 360,
          child: AnnotationCanvas(editor: editor, tool: AnnotationTool.eraser, color: Colors.red, width: 5, opacity: 1),
        ),
      ),
    ),
  );

  testWidgets('curved stroke hits its middle segments and leaves empty enclosed space untouched', (tester) async {
    final original = element('curve', AnnotationTool.pen, const [
      Offset(.2, .2),
      Offset(.8, .2),
      Offset(.8, .8),
      Offset(.2, .8),
    ]);
    final editor = AnnotationEditor()..add(original);
    await pumpCanvas(tester, editor);
    await tester.tapAt(imagePoint(tester, const Offset(.5, .5)));
    expect(editor.elements.single, original);
    await tester.tapAt(imagePoint(tester, const Offset(.8, .5)));
    expect(editor.elements, isEmpty);
    expect(editor.undo(), isTrue);
    expect(editor.elements.single, original);
    expect(editor.redo(), isTrue);
    expect(editor.elements, isEmpty);
  });

  for (final tool in [AnnotationTool.rectangle, AnnotationTool.ellipse]) {
    testWidgets('$tool empty center does not erase its outline', (tester) async {
      final original = element('outline', tool, const [Offset(.2, .2), Offset(.8, .8)]);
      final editor = AnnotationEditor()..add(original);
      await pumpCanvas(tester, editor);
      await tester.tapAt(imagePoint(tester, const Offset(.5, .5)));
      expect(editor.elements.single, original);
      await tester.tapAt(imagePoint(tester, const Offset(.5, .2)));
      expect(editor.elements, isEmpty);
      expect(editor.undo(), isTrue);
      expect(editor.elements.single, original);
      // The missed center tap must not add an undo entry.
      expect(editor.undo(), isTrue);
      expect(editor.elements, isEmpty);
      expect(editor.undo(), isFalse);
    });
  }

  testWidgets('arrow wing beyond the shaft tolerance is erasable', (tester) async {
    final original = element('arrow', AnnotationTool.arrow, const [Offset(.2, .5), Offset(.8, .5)], width: 18);
    final editor = AnnotationEditor()..add(original);
    await pumpCanvas(tester, editor);
    final head = original.width * 4 + 8;
    final wing = Offset(.8 - head * math.cos(math.pi / 6) / 360, .5 - head * math.sin(math.pi / 6) / 360);
    await tester.tapAt(imagePoint(tester, wing));
    expect(editor.elements, isEmpty);
    expect(editor.undo(), isTrue);
    expect(editor.elements.single, original);
  });

  testWidgets('long multiline text is erasable at the end of its actual layout', (tester) async {
    final original = element('text', AnnotationTool.text, const [
      Offset(.1, .1),
    ], text: 'A long caption that wraps across several lines\nand ends here');
    final editor = AnnotationEditor()..add(original);
    await pumpCanvas(tester, editor);
    final painter = layoutAnnotationText(original, const Size.square(360));
    expect(painter.computeLineMetrics().length, greaterThan(1));
    final end = const Offset(36, 36) + Offset(painter.width - 4, painter.height - 4);
    painter.dispose();
    await tester.tapAt(imagePoint(tester, end / 360));
    expect(editor.elements, isEmpty);
    expect(editor.undo(), isTrue);
    expect(editor.elements.single, original);
  });

  testWidgets('tap removes only the top overlapping element, and undo restores its order', (tester) async {
    final bottom = element('bottom', AnnotationTool.pen, const [Offset(.2, .5), Offset(.8, .5)]);
    final top = element('top', AnnotationTool.highlighter, bottom.points);
    final editor = AnnotationEditor()
      ..add(bottom)
      ..add(top);
    await pumpCanvas(tester, editor);
    await tester.tapAt(imagePoint(tester, const Offset(.5, .5)));
    expect(editor.elements, [bottom]);
    expect(editor.undo(), isTrue);
    expect(editor.elements, [bottom, top]);
    expect(editor.redo(), isTrue);
    expect(editor.elements, [bottom]);
  });

  testWidgets('eraser uses transformed coordinates after pinch, pan, rotation and reflection', (tester) async {
    final original = element('stroke', AnnotationTool.pen, const [Offset(.3, .4), Offset(.7, .4)]);
    final editor = AnnotationEditor()..add(original);
    final navigation = ValueNotifier(false);
    addTearDown(navigation.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 400,
            child: EditorViewport(
              contentSize: const Size.square(360),
              navigationActive: navigation,
              child: RotatedBox(
                quarterTurns: 1,
                child: Transform.flip(
                  flipX: true,
                  child: SizedBox.square(
                    dimension: 360,
                    child: AnnotationCanvas(
                      editor: editor,
                      tool: AnnotationTool.eraser,
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
    await first.moveTo(center - const Offset(60, 0) + const Offset(15, 10));
    await second.moveTo(center + const Offset(60, 0) + const Offset(15, 10));
    await first.up();
    await second.up();
    await tester.pump();
    expect(tester.widget<Transform>(find.byKey(const Key('editor-zoom-transform'))).transform.getMaxScaleOnAxis(), 1.5);
    expect(editor.elements.single, original);
    await tester.tapAt(imagePoint(tester, const Offset(.5, .4)));
    expect(editor.elements, isEmpty);
    expect(editor.undo(), isTrue);
    expect(editor.elements.single, original);
  });
}
