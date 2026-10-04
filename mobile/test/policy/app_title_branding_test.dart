import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every MaterialApp title is localized within its localization context', () {
    const sources = ['lib/main.dart', 'lib/pages/common/splash_screen.page.dart'];

    for (final path in sources) {
      final content = File(path).readAsStringSync();
      expect(content, isNot(contains("title: 'Immich'")), reason: path);
      expect(content, contains('onGenerateTitle: (appContext) => appContext.t.app_name'), reason: path);
    }
  });
}
