import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:mocktail/mocktail.dart';

class _Settings extends Mock implements AppSettingsService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('selection and impact honor the live persisted on/off setting', () async {
    final settings = _Settings();
    var enabled = true;
    when(() => settings.getSetting(AppSettingsEnum.enableHapticFeedback)).thenAnswer((_) => enabled);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final container = ProviderContainer(overrides: [appSettingsServiceProvider.overrideWithValue(settings)]);
    addTearDown(container.dispose);
    final haptics = container.read(hapticFeedbackProvider.notifier);
    haptics.selectionClick();
    haptics.mediumImpact();
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.arguments), ['HapticFeedbackType.selectionClick', 'HapticFeedbackType.mediumImpact']);
    enabled = false;
    haptics.selectionClick();
    haptics.mediumImpact();
    await Future<void>.delayed(Duration.zero);
    expect(calls, hasLength(2));
  });
}
