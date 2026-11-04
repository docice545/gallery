import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/pages/edit/edit.page.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';

import 'editor_compact_layout_test.dart' show editorPhotoRect, pumpCompactEditor, selectEditorMode, tapEditorControl;

void main() {
  for (final size in [const Size(393, 852), const Size(568, 320)]) {
    for (final fraction in [.5, .9]) {
      testWidgets('popover avoids the actual stroke endpoint at $fraction on $size without resizing the photo', (
        tester,
      ) async {
        final landscape = size.width > size.height;
        await pumpCompactEditor(
          tester,
          size: size,
          scale: 2,
          portrait: !landscape,
          padding: landscape
              ? const FakeViewPadding(left: 24, right: 24, bottom: 24)
              : const FakeViewPadding(top: 28, bottom: 24),
        );
        await selectEditorMode(tester, 'draw');
        final viewport = editorPhotoRect(tester);
        final dock = tester.getRect(find.byKey(const Key('editor-bottom-panel')));
        final image = tester.getRect(find.byKey(const Key('editor-image-surface')));
        final end = Offset(image.center.dx, image.top + image.height * fraction);
        await tester.dragFrom(end - const Offset(15, 0), const Offset(15, 0));
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
        final edits = container.read(editorStateProvider);
        expect(edits.annotations, isNotEmpty);
        for (final parameter in ['width', 'opacity', 'color']) {
          await tapEditorControl(tester, 'editor-$parameter');
          final popover = find.byKey(const Key('editor-parameter-popover'));
          expect(popover, findsOneWidget);
          final bounds = tester.getRect(popover);
          expect(bounds.inflate(16).contains(end), isFalse);
          expect(bounds.height, lessThanOrEqualTo(160));
          expect(bounds.top, greaterThanOrEqualTo(viewport.top));
          expect(bounds.bottom, lessThan(viewport.bottom));
          expect(editorPhotoRect(tester), viewport);
          expect(tester.getRect(find.byKey(const Key('editor-bottom-panel'))), dock);
          expect(container.read(editorStateProvider), edits);
          await tester.tapAt(const Offset(1, 1));
          await tester.pumpAndSettle();
          expect(popover, findsNothing);
          expect(tester.takeException(), isNull);
        }
        // The former drawing point stays hit-testable while parameters are up.
        await tapEditorControl(tester, 'editor-width');
        await tester.dragFrom(end, const Offset(15, -5));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('editor-parameter-popover')), findsNothing);
        expect(container.read(editorStateProvider).annotations.length, edits.annotations.length + 1);
        expect(editorPhotoRect(tester), viewport);
      });
    }
  }
}
