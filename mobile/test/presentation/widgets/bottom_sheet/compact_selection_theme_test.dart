import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';

import 'toolbar_test_app.dart';

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('compact selection toolbar: $brightness', (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var actionCount = 0;

      await tester.pumpWidget(
        toolbarTestApp(
          theme: ThemeData(brightness: brightness, useMaterial3: true),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: CompactSelectionToolbar(
                deleteButton: const Icon(Icons.delete_outline),
                shareButton: const Icon(Icons.share_rounded),
                createButton: const Icon(Icons.create_new_folder_outlined),
                moreActions: [ListTile(title: const Text('Архивировать'), onTap: () => actionCount++)],
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final toolbar = find.byType(CompactSelectionToolbar);
      final row = find.descendant(of: toolbar, matching: find.byType(Row));

      expect(tester.getSize(row.first).height, 76);

      await tester.tap(find.byKey(const ValueKey('selection-more-button')));
      await tester.pumpAndSettle();

      expect(find.text('Архивировать'), findsOneWidget);
      expect(tester.getSize(row.first).height, 76);

      await tester.tap(find.text('Архивировать'));
      await tester.pumpAndSettle();

      expect(actionCount, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
