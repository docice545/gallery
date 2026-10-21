import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';

void main() {
  late ProviderContainer container;
  late EditorProvider editor;
  EditorState state() => container.read(editorStateProvider);
  setUp(() {
    container = ProviderContainer();
    editor = container.read(editorStateProvider.notifier);
  });
  tearDown(() => container.dispose());
  AnnotationElement caption() => AnnotationElement(
    id: 'caption',
    tool: AnnotationTool.text,
    points: const [Offset(.2, .3)],
    color: const Color(0xffff0000),
    width: 2,
    opacity: .7,
    text: 'Family',
  );

  test('undo and redo traverse geometry, corrections, filters and styled markup in order', () {
    editor.setCrop(const Rect.fromLTWH(.1, .2, .8, .7));
    editor.rotateCW();
    editor.setAdjustment('brightness', .2);
    editor.setFilter(32, intensity: .5);
    editor.setAnnotations([caption().copyWith(fontFamily: 'serif', outlineWidth: .006, rotation: .3, scale: 1.5)]);
    final finalState = state();
    editor.undo();
    expect(state().annotations, isEmpty);
    expect(state().selectedFilterIndex, 32);
    editor.undo();
    expect(state().selectedFilterIndex, 0);
    expect(state().adjustments, {'brightness': .2});
    editor.undo();
    expect(state().adjustments, isEmpty);
    expect(state().rotationAngle, 90);
    editor.undo();
    expect(state().rotationAngle, 0);
    expect(state().crop.left, .1);
    editor.undo();
    expect(state().hasEdits, isFalse);
    expect(state().canUndo, isFalse);
    for (var i = 0; i < 5; i++) {
      editor.redo();
    }
    expect(state().annotations, finalState.annotations);
    expect(state().crop, finalState.crop);
    expect(state().selectedFilterIndex, 32);
    expect(state().canRedo, isFalse);
  });
  test('one continuous slider gesture is one undo step and redo restores the final value', () {
    editor.beginGesture();
    for (var i = 1; i <= 1000; i++) {
      editor.setAdjustment('exposure', i / 1000);
    }
    editor.endGesture();
    editor.undo();
    expect(state().adjustments, isEmpty);
    expect(state().canUndo, isFalse);
    editor.redo();
    expect(state().adjustments, {'exposure': 1});
  });
  test('no-op interactions do not consume history or discard redo', () {
    editor.setFilter(4);
    editor.undo();
    editor.beginGesture();
    editor.setAdjustment('brightness', 0);
    editor.endGesture();
    editor.setCrop(state().crop);
    editor.setAnnotations([]);
    expect(state().canUndo, isFalse);
    expect(state().canRedo, isTrue);
    editor.redo();
    expect(state().selectedFilterIndex, 4);
  });
  test('a new edit after undo invalidates redo', () {
    editor.setFilter(3);
    editor.undo();
    editor.flipHorizontally();
    expect(state().canRedo, isFalse);
    editor.redo();
    expect(state().selectedFilterIndex, 0);
  });
  test('reset is one reversible document change including annotations', () {
    editor.setAnnotations([caption()]);
    editor.rotateCCW();
    editor.setAdjustment('hue', .3);
    final before = state();
    editor.resetEdits();
    expect(state().hasEdits, isFalse);
    expect(state().annotations, isEmpty);
    editor.undo();
    expect(state().annotations, before.annotations);
    expect(state().adjustments, before.adjustments);
    expect(state().rotationAngle, before.rotationAngle);
    editor.redo();
    expect(state().hasEdits, isFalse);
  });
  test('four turns and zero-intensity effects are clean', () {
    for (var i = 0; i < 4; i++) {
      editor.rotateCCW();
    }
    expect(state().hasEdits, isFalse);
    editor.setFilter(32, intensity: 0);
    expect(state().hasEdits, isFalse);
  });
  test('history retains at most 100 immutable snapshots', () {
    for (var i = 1; i <= 130; i++) {
      editor.setAdjustment('contrast', i / 200);
    }
    for (var i = 0; i < 100; i++) {
      expect(state().canUndo, isTrue);
      editor.undo();
    }
    expect(state().canUndo, isFalse);
    expect(state().adjustments['contrast'], closeTo(.15, 1e-10));
  });
  test('saving locks all document mutations, undo and redo', () {
    editor.setAnnotations([caption()]);
    editor.setIsEditing(true);
    editor.setFilter(32);
    editor.undo();
    editor.setAnnotations([]);
    editor.redo();
    expect(state().annotations, hasLength(1));
    expect(state().selectedFilterIndex, 0);
    editor.setIsEditing(false);
    editor.undo();
    expect(state().annotations, isEmpty);
  });
  test('invalid geometry and non-finite corrections fail without changing the document', () {
    expect(() => editor.setCrop(const Rect.fromLTWH(-.1, 0, 1, 1)), throwsArgumentError);
    expect(() => editor.setAdjustment('hue', double.nan), throwsArgumentError);
    expect(() => editor.setFilter(2, intensity: double.infinity), throwsArgumentError);
    expect(state().hasEdits, isFalse);
    expect(state().canUndo, isFalse);
  });
}
