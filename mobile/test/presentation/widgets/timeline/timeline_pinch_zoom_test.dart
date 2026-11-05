import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_pinch_zoom.dart';

void main() {
  testWidgets('retained Timeline rebases pinch on an external density change', (tester) async {
    final db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    final settings = await SettingsRepository.ensureInitialized(db);
    addTearDown(() async {
      await SettingsRepository.reset();
      await db.close();
    });
    var changes = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: TimelinePinchZoom(
            key: const Key('retained-pinch'),
            onColumnCountWillChange: () => changes++,
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );
    final original = tester.state(find.byType(TimelinePinchZoom));
    expect(settings.appConfig.timeline.tilesPerRow, 4);
    await settings.write(.timelineTilesPerRow, 2);
    await tester.pump();
    expect(tester.state(find.byType(TimelinePinchZoom)), same(original));
    final left = await tester.startGesture(const Offset(250, 250), pointer: 1);
    final right = await tester.startGesture(const Offset(350, 250), pointer: 2);
    await left.moveBy(const Offset(-20, 0));
    await right.moveBy(const Offset(20, 0));
    await tester.pump();
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(settings.appConfig.timeline.tilesPerRow, 2);
    expect(changes, 0, reason: 'Zooming in at the largest size must not jump to stale density 3 or 4');
  });
}
