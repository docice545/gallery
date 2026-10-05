import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/magic_eraser.model.dart';

void main() {
  MagicEraserStroke stroke({bool erase = false, List<Offset>? points, double radius = 0.05}) =>
      MagicEraserStroke(points: points ?? [const Offset(0.25, 0.5)], radius: radius, erase: erase);

  group('MagicEraserStroke', () {
    test('snapshots normalized points without allowing later input or output mutation', () {
      final input = [const Offset(0.25, 0.5)];
      final selection = stroke(points: input);
      input.add(const Offset(0.75, 0.5));

      expect(selection.points, [const Offset(0.25, 0.5)]);
      expect(() => selection.points.add(Offset.zero), throwsUnsupportedError);
    });

    test('accepts boundary coordinates and the largest supported brush', () {
      final selection = stroke(points: [Offset.zero, const Offset(1, 1)], radius: 0.25);
      expect(selection.points, [Offset.zero, const Offset(1, 1)]);
      expect(selection.radius, 0.25);
    });

    test('rejects a brush outside the normalized image or nonfinite coordinates', () {
      for (final point in [
        const Offset(-0.01, 0.5),
        const Offset(1.01, 0.5),
        const Offset(0.5, -0.01),
        const Offset(0.5, 1.01),
        const Offset(double.nan, 0.5),
        const Offset(0.5, double.infinity),
      ]) {
        expect(() => stroke(points: [point]), throwsArgumentError, reason: '$point');
      }
    });

    test('rejects empty or excessively sampled gestures', () {
      expect(() => stroke(points: []), throwsArgumentError);
      expect(() => stroke(points: List.filled(513, const Offset(0.5, 0.5))), throwsArgumentError);
    });

    test('rejects zero, negative, excessive and nonfinite brush sizes', () {
      for (final radius in [0.0, 0.0009, -0.01, 0.2501, double.nan, double.infinity]) {
        expect(() => stroke(radius: radius), throwsArgumentError, reason: '$radius');
      }
    });

    test('records erasing as a mask operation without changing the original gesture', () {
      final brush = stroke();
      final eraser = stroke(erase: true);
      expect(brush.erase, isFalse);
      expect(eraser.erase, isTrue);
      expect(eraser.points, brush.points);
      expect(eraser.radius, brush.radius);
    });

    test('sends normalized mask instructions rather than source image bytes', () {
      final gesture = stroke(points: [const Offset(0.25, 0.5), const Offset(0.75, 0.5)], erase: true);

      expect(gesture.toJson(), {
        'points': [
          {'x': 0.25, 'y': 0.5},
          {'x': 0.75, 'y': 0.5},
        ],
        'radius': 0.05,
        'erase': true,
      });
    });
  });

  group('MagicEraserMask', () {
    test('starts with no selection or history', () {
      final mask = MagicEraserMask();
      expect(mask.strokes, isEmpty);
      expect(mask.hasSelection, isFalse);
      expect(mask.canUndo, isFalse);
      expect(mask.canRedo, isFalse);
    });

    test('eraser-only gestures do not permit an inpainting request', () {
      expect(MagicEraserMask().add(stroke(erase: true)).hasSelection, isFalse);
    });

    test('add, undo and redo preserve the previous immutable snapshots', () {
      final first = stroke();
      final second = stroke(points: [const Offset(0.75, 0.5)], erase: true);
      final initial = MagicEraserMask();
      final one = initial.add(first);
      final two = one.add(second);
      final undone = two.undo();
      final redone = undone.redo();

      expect(initial.strokes, isEmpty);
      expect(one.strokes, [first]);
      expect(two.strokes, [first, second]);
      expect(undone.strokes, [first]);
      expect(undone.canRedo, isTrue);
      expect(redone.strokes, [first, second]);
      expect(redone.canRedo, isFalse);
      expect(one.hasSelection, isTrue);
    });

    test('a new gesture after undo discards redo rather than reviving a removed object mask', () {
      final first = stroke();
      final second = stroke(points: [const Offset(0.75, 0.5)]);
      final replacement = stroke(points: [const Offset(0.5, 0.75)]);
      final edited = MagicEraserMask().add(first).add(second).undo().add(replacement);

      expect(edited.strokes, [first, replacement]);
      expect(edited.canRedo, isFalse);
      expect(edited.redo().strokes, [first, replacement]);
    });

    test('undoing all gestures removes the selection and preserves redo ordering', () {
      final first = stroke();
      final second = stroke(points: [const Offset(0.75, 0.5)]);
      final empty = MagicEraserMask().add(first).add(second).undo().undo();

      expect(empty.hasSelection, isFalse);
      expect(empty.canUndo, isFalse);
      expect(empty.canRedo, isTrue);
      expect(empty.redo().redo().strokes, [first, second]);
      expect(empty.undo().strokes, isEmpty);
    });

    test('reset removes both mask and redo history without modifying existing snapshots', () {
      final first = stroke();
      final beforeReset = MagicEraserMask().add(first).add(stroke(erase: true)).undo();
      final reset = beforeReset.reset();

      expect(reset.strokes, isEmpty);
      expect(reset.hasSelection, isFalse);
      expect(reset.canUndo, isFalse);
      expect(reset.canRedo, isFalse);
      expect(beforeReset.strokes, [first]);
      expect(beforeReset.canRedo, isTrue);
    });

    test('snapshots constructor input and exposes an immutable mask', () {
      final first = stroke();
      final input = [first];
      final mask = MagicEraserMask(strokes: input);
      input.clear();

      expect(mask.strokes, [first]);
      expect(() => mask.strokes.clear(), throwsUnsupportedError);
    });

    test('limits gesture count without modifying the accepted mask', () {
      final accepted = MagicEraserMask(strokes: List.generate(64, (_) => stroke()));

      expect(() => accepted.add(stroke()), throwsArgumentError);
      expect(accepted.strokes, hasLength(64));
      expect(() => MagicEraserMask(strokes: List.generate(65, (_) => stroke())), throwsArgumentError);
    });

    test('limits total sample count even when every individual gesture is valid', () {
      final strokes = List.generate(16, (_) => stroke(points: List.filled(512, const Offset(0.5, 0.5))));
      final accepted = MagicEraserMask(strokes: strokes);

      expect(() => accepted.add(stroke()), throwsArgumentError);
      expect(accepted.strokes, hasLength(16));
      expect(() => MagicEraserMask(strokes: [...strokes, stroke()]), throwsArgumentError);
    });
  });

  group('MagicEraserJob', () {
    test('reads processing lifecycle states without inventing an edited asset', () {
      for (final status in MagicEraserStatus.values) {
        final job = MagicEraserJob.fromJson({'id': 'job-id', 'status': status.name});
        expect(job.id, 'job-id');
        expect(job.status, status);
        expect(job.assetId, isNull);
      }
    });

    test('reads a saved copy and a failure code distinctly', () {
      final saved = MagicEraserJob.fromJson({'id': 'saved-job', 'status': 'saved', 'assetId': 'new-asset-id'});
      final failed = MagicEraserJob.fromJson({
        'id': 'failed-job',
        'status': 'failed',
        'errorCode': 'inpainting_failed',
      });

      expect(saved.assetId, 'new-asset-id');
      expect(saved.errorCode, isNull);
      expect(failed.assetId, isNull);
      expect(failed.errorCode, 'inpainting_failed');
    });
  });
}
