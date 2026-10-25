import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_ui/src/snackbar.dart';

import 'test_utils.dart';

void main() {
  group('SnackbarManager', () {
    testWidgets('shows the message', (tester) async {
      await tester.pumpTestWidget(const SizedBox());

      snackbar.success('hello');
      await tester.pump();

      expect(find.text('hello'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('replaces the current snackbar', (tester) async {
      await tester.pumpTestWidget(const SizedBox());

      snackbar.info('first');
      await tester.pump();
      snackbar.error('second');
      await tester.pump();

      expect(find.text('first'), findsNothing);
      expect(find.text('second'), findsOneWidget);
    });

    testWidgets('no-ops when the messenger is unmounted', (tester) async {
      expect(snackbar.show('x', .info), isNull);
    });

    testWidgets('long deletion results remain readable and scroll within a compact notification', (tester) async {
      tester.view.physicalSize = const Size(960, 1800);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const footerKey = Key('bottom-controls');
      await tester.pumpWidget(
        MaterialApp(
          scaffoldMessengerKey: scaffoldMessengerKey,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: const Scaffold(
            body: SizedBox.expand(),
            bottomNavigationBar: SizedBox(key: footerKey, height: 90),
          ),
        ),
      );
      final message = '${List.filled(25, 'Оригинал сохранён: разрешение на удаление отсутствует.').join(' ')} Конец.';
      snackbar.error(message);
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text(message));
      expect(text.maxLines, isNull);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
      final scroller = find.descendant(of: find.byType(SnackBar), matching: find.byType(SingleChildScrollView));
      expect(tester.getSize(scroller).height, lessThanOrEqualTo(180));
      expect(
        tester.getRect(find.byType(SnackBar)).bottom,
        lessThanOrEqualTo(tester.getRect(find.byKey(footerKey)).top),
      );
      final scrollable = find.descendant(of: scroller, matching: find.byType(Scrollable));
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));
      await tester.drag(scroller, const Offset(0, -10000));
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.1));
      expect(tester.takeException(), isNull);
    });
  });
}
