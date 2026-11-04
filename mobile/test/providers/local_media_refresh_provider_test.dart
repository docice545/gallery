import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/services/device_permission.service.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/providers/app_life_cycle.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/local_media_refresh.provider.dart';
import 'package:mocktail/mocktail.dart';

class _Permission extends Mock implements DevicePermissionService {}

class _Lifecycle extends AppLifeCycleNotifier {
  _Lifecycle(super.ref);
  void change(AppLifeCycleEnum value) => state = value;
}

class _Manager extends BackgroundSyncManager {
  int calls = 0;
  @override
  Future<void> syncLocal({bool full = false, bool enqueue = false}) async {
    expect(full, isFalse);
    expect(enqueue, isTrue);
    calls++;
  }
}

void main() {
  testWidgets('native notifications reach delta sync; pause stops observation and resume catches up', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final permission = _Permission();
    when(permission.galleryStatus).thenAnswer((_) async => DevicePermissionStatus.granted);
    final manager = _Manager();
    final toggles = <bool>[];
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    const notify = MethodChannel('com.fluttercandies/photo_manager/notify');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'notify') {
        toggles.add((call.arguments as Map)['notify'] as bool);
      }
      return null;
    });
    final container = ProviderContainer(
      overrides: [
        galleryPermissionServiceProvider.overrideWithValue(permission),
        backgroundSyncProvider.overrideWithValue(manager),
        appStateProvider.overrideWith((ref) => _Lifecycle(ref)),
      ],
    );
    final listener = container.listen(localMediaRefreshProvider, (_, _) {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(toggles, [true]);
    expect(manager.calls, 1);
    await messenger.handlePlatformMessage(
      notify.name,
      notify.codec.encodeMethodCall(const MethodCall('change', {'type': 'insert', 'id': '123'})),
      (_) {},
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(manager.calls, 2);
    final lifecycle = container.read(appStateProvider.notifier) as _Lifecycle;
    lifecycle.change(AppLifeCycleEnum.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(toggles, [true, false]);
    expect(manager.calls, 2);
    lifecycle.change(AppLifeCycleEnum.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(toggles, [true, false, true]);
    expect(manager.calls, 3);
    listener.close();
    container.dispose();
    await tester.pump();
    expect(toggles, [true, false, true, false]);
    messenger.setMockMethodCallHandler(channel, null);
  });
}
