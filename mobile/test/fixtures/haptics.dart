import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/services/app_settings.service.dart';

/// Standalone editor fixtures do not boot the persisted app store. Dedicated
/// haptic tests override this fixture and inspect actual platform channel calls.
class TestAppSettingsService extends AppSettingsService {
  TestAppSettingsService({this.haptics = false});
  bool haptics;

  @override
  T getSetting<T>(AppSettingsEnum<T> setting) =>
      setting == AppSettingsEnum.enableHapticFeedback ? haptics as T : setting.defaultValue;
}

final testHapticsOverride = appSettingsServiceProvider.overrideWithValue(TestAppSettingsService());
