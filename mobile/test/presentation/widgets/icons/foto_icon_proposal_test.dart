import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_mode.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon_mapping.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon_paths.dart';
import 'package:immich_mobile/utils/action_button.utils.dart';

void main() {
  test('proposal maps every existing editor mode, annotation tool and viewer action', () {
    expect(fotoEditorModeIcons.keys, unorderedEquals(EditorMode.values));
    expect(fotoAnnotationToolIcons.keys, unorderedEquals(AnnotationTool.values));
    expect(fotoViewerActionIcons.keys, unorderedEquals(ActionButtonType.values));
    expect(fotoIconPaths.keys, unorderedEquals(FotoIconKind.values));
    expect(fotoViewerActionIcons[ActionButtonType.deleteLocal], isNot(fotoViewerActionIcons[ActionButtonType.delete]));
    expect(fotoIconPaths.values.every((path) => path.startsWith('<path d=')), isTrue);
  });

  testWidgets('viewer surface retains enabled icon contrast over the brightest photo and secondary action', (
    tester,
  ) async {
    var primary = 0;
    var secondary = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ViewerControlSurface(
            child: FotoIconButton(
              kind: FotoIconKind.share,
              label: 'Share',
              onPressed: () => primary++,
              onLongPress: () => secondary++,
            ),
          ),
        ),
      ),
    );
    final context = tester.element(find.byType(FotoIconButton));
    final colors = Theme.of(context).colorScheme;
    final material = tester.widget<Material>(
      find.descendant(of: find.byType(ViewerControlSurface), matching: find.byType(Material)).first,
    );
    final worstBackground = Color.alphaBlend(material.color!, Colors.white);
    for (final foreground in [colors.onSurface, colors.primary, colors.error]) {
      expect(
        (foreground.computeLuminance() + .05) / (worstBackground.computeLuminance() + .05),
        greaterThanOrEqualTo(4.5),
      );
    }
    expect(
      (colors.primary.computeLuminance() + .05) / (colors.primaryContainer.computeLuminance() + .05),
      greaterThanOrEqualTo(3),
    );
    await tester.longPress(find.byTooltip('Share'));
    expect(secondary, 1);
    expect(primary, 0);
  });

  for (final brightness in Brightness.values) {
    for (final size in [20.0, 22.0, 24.0]) {
      testWidgets('icon-only $size dp proposal renders states and retains 48 dp actions in $brightness', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        try {
          var taps = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff4150af), brightness: brightness),
              ),
              home: Scaffold(
                body: Row(
                  children: [
                    FotoIconButton(kind: FotoIconKind.edit, label: 'Edit photo', size: size, onPressed: () => taps++),
                    FotoIconButton(
                      kind: FotoIconKind.favorite,
                      label: 'Favorite',
                      size: size,
                      selected: true,
                      onPressed: () => taps++,
                    ),
                    FotoIconButton(kind: FotoIconKind.undo, label: 'Undo', size: size, onPressed: null),
                    FotoIconButton(
                      kind: FotoIconKind.trash,
                      label: 'Move to trash',
                      size: size,
                      destructive: true,
                      onPressed: () => taps++,
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(Text), findsNothing, reason: 'Persistent captions belong only in the review sheet');
          for (final element in find.byType(FotoIconButton).evaluate()) {
            expect(tester.getSize(find.byWidget(element.widget)), const Size.square(48));
          }
          for (final image in tester.widgetList<SvgPicture>(find.byType(SvgPicture))) {
            expect(image.width, size);
            expect(image.height, size);
          }
          expect(find.byTooltip('Edit photo'), findsOneWidget);
          expect(find.bySemanticsLabel('Edit photo'), findsOneWidget);
          expect(tester.widgetList<FotoIcon>(find.byType(FotoIcon)).map((icon) => icon.state), [
            FotoIconState.normal,
            FotoIconState.active,
            FotoIconState.disabled,
            FotoIconState.destructive,
          ]);
          await tester.tap(find.byTooltip('Edit photo'));
          await tester.tap(find.byTooltip('Undo'));
          expect(taps, 1);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
