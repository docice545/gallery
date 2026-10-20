import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/utils/annotation_editor.dart';

AnnotationElement stroke(String id, {AnnotationTool tool = AnnotationTool.pen}) => AnnotationElement(
  id: id,
  tool: tool,
  points: const [Offset(0.2, 0.3), Offset(0.4, 0.5)],
  color: const Color(0xffff0000),
  width: 0.01,
  opacity: 0.8,
);

void main() {
  for (final delta in [const Offset(2, 2), const Offset(-2, -2), const Offset(-2, 2), const Offset(2, -2)]) {
    test('moving to boundary $delta preserves every relative point and style', () {
      final original = stroke('curve').copyWith(points: const [Offset(.2, .3), Offset(.8, .6), Offset(.4, .5)]);
      final editor = AnnotationEditor()..add(original);
      editor.move(original.id, delta);
      final moved = editor.elements.single;
      final applied = moved.points.first - original.points.first;
      for (var index = 0; index < original.points.length; index++) {
        expect((moved.points[index] - original.points[index] - applied).distance, lessThan(1e-9));
        expect(moved.points[index].dx, inInclusiveRange(0, 1));
        expect(moved.points[index].dy, inInclusiveRange(0, 1));
      }
      expect(moved, original.copyWith(points: moved.points));
      expect(editor.undo(), isTrue);
      expect(editor.elements.single, original);
      expect(editor.redo(), isTrue);
      expect(editor.elements.single, moved);
    });
  }

  test('records strokes and supports undo and redo', () {
    final editor = AnnotationEditor();
    editor.add(stroke('one'));
    editor.add(stroke('two', tool: AnnotationTool.highlighter));

    expect(editor.elements.map((element) => element.id), ['one', 'two']);
    expect(editor.undo(), isTrue);
    expect(editor.elements.map((element) => element.id), ['one']);
    expect(editor.redo(), isTrue);
    expect(editor.elements.map((element) => element.id), ['one', 'two']);
  });

  test('a new mutation clears redo and moving preserves style', () {
    final editor = AnnotationEditor();
    editor.add(stroke('one'));
    expect(editor.move('one', const Offset(0.1, -0.2)), isTrue);
    expect(editor.elements.single.points[0].dx, closeTo(0.3, 1e-9));
    expect(editor.elements.single.points[0].dy, closeTo(0.1, 1e-9));
    expect(editor.elements.single.points[1].dx, closeTo(0.5, 1e-9));
    expect(editor.elements.single.points[1].dy, closeTo(0.3, 1e-9));
    expect(editor.undo(), isTrue);
    expect(editor.elements.single.points[0].dx, closeTo(0.2, 1e-9));
    expect(editor.elements.single.points[0].dy, closeTo(0.3, 1e-9));
    expect(editor.elements.single.points[1].dx, closeTo(0.4, 1e-9));
    expect(editor.elements.single.points[1].dy, closeTo(0.5, 1e-9));
    editor.add(stroke('two'));
    expect(editor.canRedo, isFalse);
  });

  test('remove and clear are undoable and unknown ids are harmless', () {
    final editor = AnnotationEditor();
    editor.add(stroke('one'));
    expect(editor.remove('missing'), isFalse);
    expect(editor.remove('one'), isTrue);
    expect(editor.elements, isEmpty);
    expect(editor.undo(), isTrue);
    expect(editor.elements.single.id, 'one');
    editor.clear();
    expect(editor.elements, isEmpty);
    expect(editor.undo(), isTrue);
    expect(editor.elements.single.id, 'one');
  });
}
