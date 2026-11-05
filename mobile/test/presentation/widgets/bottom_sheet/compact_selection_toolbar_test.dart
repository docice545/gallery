import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';

import 'toolbar_test_app.dart';

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
      toolbarTestApp(
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
  for (final locale in ['en', 'ru']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('$locale selection keeps 48dp actions at text scale $scale with safe insets', (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(bottom: 24);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        Widget button(String id) => IconButton(key: ValueKey(id), icon: const Icon(Icons.add), onPressed: () {});
        await tester.pumpWidget(
          toolbarTestApp(
            locale: Locale(locale),
            home: Scaffold(
              bottomSheet: CompactSelectionToolbar(
                deleteButton: button('delete'),
                shareButton: button('share'),
                createButton: button('create'),
                moreActions: const [ListTile(title: Text('Extra'))],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final id in ['delete', 'share', 'create', 'selection-more-button']) {
          final rect = tester.getRect(find.byKey(ValueKey(id)));
          expect(rect.shortestSide, greaterThanOrEqualTo(48));
          expect(rect.bottom, lessThanOrEqualTo(616));
        }
        expect(find.text(locale == 'ru' ? 'Удалить' : 'Delete'), findsOneWidget);
        final shortLabel = find.text(locale == 'ru' ? 'Ещё' : 'More');
        expect(shortLabel, findsOneWidget);
        if (locale == 'ru') {
          expect(tester.renderObject<RenderParagraph>(shortLabel).didExceedMaxLines, isFalse);
          expect(find.text('Дополнительные действия'), findsNothing);
        }
        final more = find.byKey(const ValueKey('selection-more-button'));
        final before = tester.getRect(more);
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(tester.getRect(more), before);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
