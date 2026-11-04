import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';

void main() {
  testWidgets('compact selection toolbar preserves height and actions', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var deletes = 0;
    var shares = 0;
    var creates = 0;
    var extras = 0;
    var photoTaps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('photo-area'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => photoTaps++,
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: CompactSelectionToolbar(
                  deleteButton: IconButton(
                    tooltip: 'Корзина',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => deletes++,
                  ),
                  shareButton: IconButton(
                    tooltip: 'Поделиться',
                    icon: const Icon(Icons.share_outlined),
                    onPressed: () => shares++,
                  ),
                  createButton: IconButton(
                    tooltip: 'Создать',
                    icon: const Icon(Icons.create_new_folder_outlined),
                    onPressed: () => creates++,
                  ),
                  moreActions: [ListTile(title: const Text('Архивировать'), onTap: () => extras++)],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final row = find.descendant(of: find.byType(CompactSelectionToolbar), matching: find.byType(Row));

    expect(tester.getSize(row.first).height, 76);

    await tester.tap(find.byTooltip('Корзина'));
    await tester.tap(find.byTooltip('Поделиться'));
    await tester.tap(find.byTooltip('Создать'));

    expect(deletes, 1);
    expect(shares, 1);
    expect(creates, 1);

    await tester.tap(find.byKey(const ValueKey('selection-more-button')));
    await tester.pumpAndSettle();

    expect(find.text('Архивировать'), findsOneWidget);
    expect(tester.getSize(row.first).height, 76);

    await tester.tap(find.text('Архивировать'));
    expect(extras, 1);

    await tester.tap(find.byKey(const ValueKey('selection-more-button')));
    await tester.pumpAndSettle();

    expect(find.text('Архивировать'), findsNothing);

    await tester.tapAt(const Offset(30, 200));
    await tester.pump();

    expect(photoTaps, 1);
    expect(tester.takeException(), isNull);
  });
}
