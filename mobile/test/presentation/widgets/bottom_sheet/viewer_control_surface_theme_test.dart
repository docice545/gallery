import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('viewer surface follows $brightness theme', (tester) async {
      Color? foreground;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness, useMaterial3: true),
          home: Scaffold(
            body: ViewerControlSurface(
              child: Builder(
                builder: (context) {
                  foreground = IconTheme.of(context).color;
                  return const SizedBox(width: 200, height: 64);
                },
              ),
            ),
          ),
        ),
      );

      final material = tester.widget<Material>(
        find.descendant(of: find.byType(ViewerControlSurface), matching: find.byType(Material)).first,
      );

      final colors = ThemeData(brightness: brightness, useMaterial3: true).colorScheme;
      expect(material.color, colors.surfaceContainerHigh);
      expect(foreground, colors.onSurface);

      expect(tester.takeException(), isNull);
    });
  }
}
