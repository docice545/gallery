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

      if (brightness == Brightness.dark) {
        expect(material.color, const Color(0xe6202124));
        expect(foreground, Colors.white);
      } else {
        expect(material.color, const Color(0xf5f7f8fa));
        expect(foreground, const Color(0xff202124));
      }

      expect(tester.takeException(), isNull);
    });
  }
}
