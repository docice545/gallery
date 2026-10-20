import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_viewport.dart';

void main() {
  testWidgets('zoom and pan stay bounded; cancelled touches release the navigation lock', (tester) async {
    final navigation = ValueNotifier(false);
    addTearDown(navigation.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: EditorViewport(
              contentSize: const Size(300, 100),
              navigationActive: navigation,
              child: const SizedBox(width: 300, height: 100),
            ),
          ),
        ),
      ),
    );
    final viewport = find.byType(EditorViewport);
    final center = tester.getCenter(viewport);
    final first = await tester.startGesture(center - const Offset(10, 0), pointer: 1);
    final second = await tester.startGesture(center + const Offset(10, 0), pointer: 2);
    expect(navigation.value, isTrue);
    await first.moveTo(center - const Offset(500, 0));
    await second.moveTo(center + const Offset(500, 0));
    await tester.pump();
    var matrix = tester.widget<Transform>(find.byKey(const Key('editor-zoom-transform'))).transform;
    expect(matrix.getMaxScaleOnAxis(), 8);

    await first.moveBy(const Offset(10000, 10000));
    await second.moveBy(const Offset(10000, 10000));
    await tester.pump();
    matrix = tester.widget<Transform>(find.byKey(const Key('editor-zoom-transform'))).transform;
    expect(matrix.getTranslation().x, 1050);
    expect(matrix.getTranslation().y, 300);

    await first.cancel();
    expect(navigation.value, isTrue);
    await second.cancel();
    expect(navigation.value, isFalse);

    final third = await tester.startGesture(center - const Offset(50, 0), pointer: 3);
    final fourth = await tester.startGesture(center + const Offset(50, 0), pointer: 4);
    await third.moveTo(center - const Offset(1, 0));
    await fourth.moveTo(center + const Offset(1, 0));
    await tester.pump();
    matrix = tester.widget<Transform>(find.byKey(const Key('editor-zoom-transform'))).transform;
    expect(matrix.getMaxScaleOnAxis(), 1);
    expect(matrix.getTranslation().x, 0);
    expect(matrix.getTranslation().y, 0);
    await third.up();
    await fourth.up();
    expect(tester.takeException(), isNull);
  });
}
