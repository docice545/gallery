import 'package:crop_image/crop_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/aspect_ratios.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/presentation/pages/edit/edit.page.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';

import '../../fixtures/editor_raster.dart';
import '../../test_utils.dart';
import '../../widget_tester_extensions.dart';

void main() {
  for (final (label, expectedRatio, preset, withExif) in [
    ('1:1', 1.0, CropAspectRatio.ratio1x1, true),
    ('16:9', 16 / 9, CropAspectRatio.ratio16x9, true),
    ('Original', 64 / 48, CropAspectRatio.original, true),
    ('Original', 64 / 48, CropAspectRatio.original, false),
  ]) {
    testWidgets('aspect $label withExif=$withExif forms one reversible pixel-crop history step', (tester) async {
      TestUtils.init();
      final source = (await tester.runAsync(createEditorRaster))!;
      addTearDown(source.dispose);
      final png = (await tester.runAsync(() => EditedImageExporter.encodePng(source)))!;
      await tester.runAsync(
        () => tester.pumpConsumerWidgetRaw(
          EditImagePage(image: Image.memory(png), applyEdits: (_) async {}),
          overrides: [
            immichThemeProvider.overrideWith(
              (ref) => ImmichTheme(
                light: ColorScheme.fromSeed(seedColor: Colors.blue),
                dark: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
              ),
            ),
          ],
        ),
      );
      for (var i = 0; i < 100 && find.byType(CropImage).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(find.byType(CropImage), findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
      final notifier = container.read(editorStateProvider.notifier);
      if (withExif) {
        notifier.init([], const ExifInfo(width: 64, height: 48));
      }
      await tester.pumpAndSettle();
      final baseline = container.read(editorStateProvider);
      final squareColumn = find.ancestor(of: find.text(label), matching: find.byType(Column)).first;
      final square = find.descendant(of: squareColumn, matching: find.byType(IconButton));
      await tester.ensureVisible(square);
      await tester.tap(square);
      await tester.pumpAndSettle();
      final cropped = container.read(editorStateProvider);
      expect(cropped.aspectRatio, preset);
      expect(cropped.crop.width * 64 / (cropped.crop.height * 48), closeTo(expectedRatio, .0001));
      notifier.undo();
      await tester.pumpAndSettle();
      expect(container.read(editorStateProvider).crop, baseline.crop);
      expect(container.read(editorStateProvider).aspectRatio, baseline.aspectRatio);
      expect(container.read(editorStateProvider).hasEdits, isFalse);
      expect(container.read(editorStateProvider).canUndo, isFalse);
      notifier.redo();
      await tester.pumpAndSettle();
      expect(container.read(editorStateProvider).crop, cropped.crop);
      expect(container.read(editorStateProvider).aspectRatio, cropped.aspectRatio);
      notifier.rotateCW();
      await tester.pumpAndSettle();
      expect(container.read(editorStateProvider).crop, cropped.crop);
      notifier.undo();
      await tester.pumpAndSettle();
      expect(container.read(editorStateProvider).rotationAngle, 0);
      expect(container.read(editorStateProvider).crop, cropped.crop);
      expect(container.read(editorStateProvider).canRedo, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
