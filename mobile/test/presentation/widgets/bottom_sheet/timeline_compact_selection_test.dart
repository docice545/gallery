import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/timeline_compact_selection.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';

import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

void main() {
  for (final localOnly in [true, false]) {
    testWidgets('selection exposes a real delete action for localOnly=$localOnly', (tester) async {
      final fixture = await PresentationContext.create();
      addTearDown(fixture.dispose);
      await tester.pumpTestWidget(
        fixture,
        const Align(alignment: Alignment.bottomCenter, child: TimelineCompactSelection()),
        overrides: fixture.selected({
          if (localOnly) LocalAssetFactory.create() else RemoteAssetFactory.create(ownerId: fixture.currentUser.id),
        }),
      );
      final label = localOnly ? 'Delete from Device' : 'Move to trash';
      expect(find.byTooltip(label), findsOneWidget);
      final target = tester.widget<GhostTrashTarget>(find.byType(GhostTrashTarget));
      expect(target.kind, localOnly ? GhostTrashKind.device : GhostTrashKind.server);
      expect(tester.getSize(find.byTooltip(label)).shortestSide, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });
  }
}
