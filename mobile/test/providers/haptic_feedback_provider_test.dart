import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';

import '../fixtures/haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('every signal respects the current setting without recreating its provider', () async {
    final settings = TestAppSettingsService(haptics: true);
    final container = ProviderContainer(overrides: [appSettingsServiceProvider.overrideWithValue(settings)]);
    addTearDown(container.dispose);
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final notifier = container.read(hapticFeedbackProvider.notifier);
    notifier.selectionClick();
    notifier.mediumImpact();
    notifier.heavyImpact();
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method).toSet(), {'HapticFeedback.vibrate'});
    expect(calls.map((c) => c.arguments), [
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.mediumImpact',
      'HapticFeedbackType.heavyImpact',
    ]);
    settings.haptics = false;
    notifier.selectionClick();
    notifier.mediumImpact();
    notifier.heavyImpact();
    await Future<void>.delayed(Duration.zero);
    expect(calls.length, 3);
    settings.haptics = true;
    notifier.selectionClick();
    await Future<void>.delayed(Duration.zero);
    expect(calls.length, 4);
  });
  for (final error in [PlatformException(code: 'UNAVAILABLE'), MissingPluginException()]) {
    test('unavailable system feedback does not fail the action or retry: ${error.runtimeType}', () async {
      final container = ProviderContainer(
        overrides: [appSettingsServiceProvider.overrideWithValue(TestAppSettingsService(haptics: true))],
      );
      addTearDown(container.dispose);
      var calls = 0;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async {
        calls++;
        throw error;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      container.read(hapticFeedbackProvider.notifier).mediumImpact();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
    });
  }
}
