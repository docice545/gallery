import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/action_cell_grid.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';

import 'toolbar_test_app.dart';

void main() {
  setUpAll(() async {
    await (FontLoader('GoogleSans')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final count in [2, 3, 4, 5]) {
        testWidgets('same full width shell count=$count $brightness font=$scale', (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final calls = <int>[];
          final labels = ['Отправить', 'Изменить', 'Добавить', 'Объектив', 'Удалить'].take(count).toList();
          final kinds = [
            FotoIconKind.share,
            FotoIconKind.edit,
            FotoIconKind.addAlbum,
            FotoIconKind.lens,
            FotoIconKind.trash,
          ];
          await tester.pumpWidget(
            toolbarTestApp(
              locale: const Locale('ru'),
              theme: ThemeData(brightness: brightness, fontFamily: 'GoogleSans'),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(390, 844),
                  padding: const EdgeInsets.only(bottom: 24),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.bottomCenter,
                    child: SelectionToolbarFrame(
                      child: ActionCellGrid(
                        compact: true,
                        labels: labels,
                        children: [
                          for (var i = 0; i < count; i++)
                            SelectionToolbarAction(label: labels[i], kind: kinds[i], onPressed: () => calls.add(i)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final rect = tester.getRect(find.byType(ViewerControlSurface));
          expect(rect.left, 12);
          expect(rect.width, 366);
          expect(rect.bottom, 820);
          expect(rect.height, scale == 1 ? 52 : inInclusiveRange(52, 200));
          final material = tester.widget<Material>(
            find.descendant(of: find.byType(ViewerControlSurface), matching: find.byType(Material)).first,
          );
          expect(material.shape, isA<StadiumBorder>());
          expect(material.elevation, 0);
          for (var i = 0; i < count; i++) {
            final cell = find.byKey(ValueKey('selection-action-cell-$i'));
            final button = find.descendant(of: cell, matching: find.byType(TextButton));
            final bounds = tester.getRect(button);
            expect(bounds.shortestSide, greaterThanOrEqualTo(48));
            final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: find.text(labels[i]), matching: find.byType(RichText)),
            );
            final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: labels[i].length));
            expect(boxes.map((b) => b.top).toSet(), hasLength(1));
            expect(paragraph.didExceedMaxLines, isFalse);
            // The caption and near-edge positions must hit the same action.
            await tester.tapAt(bounds.topCenter + const Offset(0, 5));
            await tester.pumpAndSettle();
            expect(calls.last, i);
          }
          expect(calls, List.generate(count, (i) => i));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
