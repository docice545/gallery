import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/base_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_ui/immich_ui.dart';

import '../../../unit/presentation/presentation_context.dart';

class _Action extends ActionBuilder {
  const _Action(this.label, this.callback);
  final String? label;
  final VoidCallback callback;
  @override
  ActionItem? create(BuildContext context, WidgetRef ref) =>
      label == null ? null : ActionItem(icon: Icons.delete_outline, label: label!, onAction: callback);
}

void main() {
  for (final size in [const Size(320, 700), const Size(393, 852), const Size(852, 393)]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets('selection actions are equal centered cells at $size textScale=$textScale with safe inset', (
        tester,
      ) async {
        final fixture = await PresentationContext.create();
        addTearDown(fixture.dispose);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var taps = 0;
        const labels = ['Удалить с устройства', 'Поделиться', 'Загрузить', 'Переместить в архив'];
        await tester.pumpWidget(
          ProviderScope(
            overrides: fixture.overrides,
            child: MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  padding: const EdgeInsets.only(bottom: 24),
                  textScaler: TextScaler.linear(textScale),
                ),
                child: Scaffold(
                  body: BaseBottomSheet(
                    initialChildSize: 1,
                    minChildSize: 1,
                    maxChildSize: 1,
                    resizeOnScroll: false,
                    actions: [
                      ActionColumnButton(action: _Action(null, () {})),
                      for (final label in labels)
                        ActionColumnButton(fotoKind: FotoIconKind.deviceTrash, action: _Action(label, () => taps++)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ImmichColumnButton), findsNWidgets(4), reason: 'hidden actions leave no blank cells');
        final rects = <Rect>[];
        for (var i = 0; i < labels.length; i++) {
          final cell = find.byKey(ValueKey('selection-action-cell-$i'));
          final rect = tester.getRect(cell);
          rects.add(rect);
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
          final icon = find.descendant(of: cell, matching: find.byType(FotoIcon));
          expect(tester.getCenter(icon).dx, closeTo(rect.center.dx, .01));
          final label = find.text(labels[i]);
          final paragraph = tester.renderObject<RenderParagraph>(label);
          expect(paragraph.didExceedMaxLines, isFalse, reason: 'the complete localized label remains readable');
        }
        for (final rect in rects) {
          expect(rect.width, closeTo(rects.first.width, .01));
        }
        expect(tester.getRect(find.byType(SingleChildScrollView)).bottom, lessThanOrEqualTo(size.height - 24));
        await tester.ensureVisible(find.text(labels.first));
        await tester.tap(find.text(labels.first));
        await tester.pumpAndSettle();
        expect(taps, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
