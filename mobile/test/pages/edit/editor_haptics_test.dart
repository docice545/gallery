import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';

import '../../fixtures/haptics.dart';
import 'editor_compact_layout_test.dart' show pumpCompactEditor, selectEditorMode;

void main() {
  testWidgets('tool selection emits one system signal and observes a live off/on preference', (tester) async {
    final settings = TestAppSettingsService(haptics: true);
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        calls.add(call);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpCompactEditor(tester, overrides: [appSettingsServiceProvider.overrideWithValue(settings)]);
    await selectEditorMode(tester, 'draw');
    expect(calls.map((c) => c.arguments), ['HapticFeedbackType.selectionClick']);
    settings.haptics = false;
    await selectEditorMode(tester, 'text');
    expect(calls.length, 1);
    settings.haptics = true;
    await selectEditorMode(tester, 'shapes');
    expect(calls.length, 2);
  });
}
