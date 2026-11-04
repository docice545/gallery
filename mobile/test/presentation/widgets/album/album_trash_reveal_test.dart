import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/album/album_trash_reveal.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';

import '../../../widget_tester_extensions.dart';

void main() {
  testWidgets('left swipe only reveals; reverse swipe closes; only explicit trash tap acts', (tester) async {
    var deleted = 0;
    var opened = 0;
    await tester.pumpConsumerWidget(
      Center(
        child: SizedBox(
          width: 320,
          child: AlbumTrashReveal(
            onTrash: () async => deleted++,
            child: SizedBox(
              height: 80,
              child: ListTile(title: const Text('Camera'), onTap: () => opened++),
            ),
          ),
        ),
      ),
    );
    final row = find.byType(AlbumTrashReveal);
    final before = tester.getSize(row);
    final cameraBefore = tester.getTopLeft(find.text('Camera'));
    await tester.drag(row, const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(deleted, 0);
    expect(opened, 0);
    expect(tester.getSize(row), before);
    final cameraAfterSwipe = tester.getTopLeft(find.text('Camera'));
    expect(cameraAfterSwipe.dx, closeTo(cameraBefore.dx - 64, 0.1));
    expect(cameraAfterSwipe.dy, closeTo(cameraBefore.dy, 0.1));
    expect(find.text('Camera'), findsOneWidget);
    expect(tester.getSize(find.byType(FotoIconButton)), const Size(48, 48));
    await tester.drag(find.byType(AlbumTrashReveal), const Offset(160, 0));
    await tester.pumpAndSettle();
    final cameraAfterReverse = tester.getTopLeft(find.text('Camera'));
    expect(cameraAfterReverse.dx, closeTo(cameraBefore.dx, 0.1));
    expect(cameraAfterReverse.dy, closeTo(cameraBefore.dy, 0.1));
    expect(deleted, 0);
    await tester.tap(find.text('Camera'));
    expect(opened, 1);
    await tester.drag(row, const Offset(-180, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete album'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
    expect(find.text('Camera'), findsOneWidget);
  });

  testWidgets('rapid swipes and repeated taps do not duplicate a pending confirmation', (tester) async {
    var calls = 0;
    final pending = Completer<void>();
    await tester.pumpConsumerWidget(
      SizedBox(
        width: 320,
        child: AlbumTrashReveal(
          onTrash: () {
            calls++;
            return pending.future;
          },
          child: const SizedBox(height: 80, child: Text('Camera')),
        ),
      ),
    );
    final row = find.byType(AlbumTrashReveal);
    await tester.drag(row, const Offset(-150, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete album'));
    await tester.pump();
    await tester.tap(find.byTooltip('Delete album'), warnIfMissed: false);
    await tester.drag(row, const Offset(150, 0));
    await tester.pump();
    expect(calls, 1);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('Camera'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
