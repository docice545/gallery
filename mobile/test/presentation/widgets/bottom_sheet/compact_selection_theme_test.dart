import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/action_cell_grid.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';

import 'toolbar_test_app.dart';

void main() {
  setUpAll(() async {
    await (FontLoader('Roboto')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
  });
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
                actions: [
                  SelectionToolbarAction(label: 'Удалить', icon: Icons.delete_outline, onPressed: () {}),
                  SelectionToolbarAction(label: 'Отправить', icon: Icons.share_rounded, onPressed: () {}),
                  SelectionToolbarAction(label: 'Добавить', icon: Icons.create_new_folder_outlined, onPressed: () {}),
                ],
                moreActions: [ListTile(title: const Text('Архивировать'), onTap: () => actionCount++)],
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final toolbar = find.byType(CompactSelectionToolbar);
      final row = find.descendant(of: toolbar, matching: find.byType(ActionCellGrid));

      final initialHeight = tester.getSize(row.first).height;
      expect(initialHeight, inInclusiveRange(48, 96));

      await tester.tap(find.byKey(const ValueKey('selection-more-button')));
      await tester.pumpAndSettle();

      expect(find.text('Архивировать'), findsOneWidget);
      expect(tester.getSize(row.first).height, initialHeight);

      await tester.tap(find.text('Архивировать'));
      await tester.pumpAndSettle();

      expect(actionCount, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
