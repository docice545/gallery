import 'dart:async';

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
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:photo_manager/photo_manager.dart';

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
    final permissionResult = Completer<DevicePermissionStatus>();
    when(permission.galleryStatus).thenAnswer((_) => permissionResult.future);
    final manager = _Manager();
    final syncErrors = <LogRecord>[];
    final logs = Logger.root.onRecord.listen((record) {
      if (record.loggerName == 'LocalMediaRefresh' && record.level >= Level.WARNING) {
        syncErrors.add(record);
      }
    });
    addTearDown(logs.cancel);
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
    var disposed = false;
    Future<void> disposeObserver() async {
      if (disposed) {
        return;
      }
      disposed = true;
      listener.close();
      container.dispose();
      // Registration/unregistration is serialized through the method channel.
      await tester.pump();
    }

    addTearDown(() async {
      await disposeObserver();
      messenger.setMockMethodCallHandler(channel, null);
    });

    // Establish the async permission/observer boundary before advancing time.
    // Merely mounting a ProviderContainer is not permission completion.
    await tester.pump();
    expect(container.read(galleryPermissionNotifier), DevicePermissionStatus.denied);
    expect(toggles, isEmpty);
    expect(manager.calls, 0);
    permissionResult.complete(DevicePermissionStatus.granted);
    await tester.pump();
    expect(container.read(galleryPermissionNotifier), DevicePermissionStatus.granted);
    expect(toggles, [true]);
    expect(PhotoManager.notifyingOfChange, isTrue);
    await tester.pump(const Duration(milliseconds: 349));
    expect(manager.calls, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(syncErrors, isEmpty);
    expect(manager.calls, 1);
    await messenger.handlePlatformMessage(
      notify.name,
      notify.codec.encodeMethodCall(const MethodCall('change', {'type': 'insert', 'id': '123'})),
      (_) {},
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 349));
    expect(manager.calls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(syncErrors, isEmpty);
    expect(manager.calls, 2);
    final lifecycle = container.read(appStateProvider.notifier) as _Lifecycle;
    lifecycle.change(AppLifeCycleEnum.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(toggles, [true, false]);
    expect(PhotoManager.notifyingOfChange, isFalse);
    expect(manager.calls, 2);
    lifecycle.change(AppLifeCycleEnum.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(toggles, [true, false, true]);
    expect(manager.calls, 3);
    expect(syncErrors, isEmpty);
    await disposeObserver();
    expect(toggles, [true, false, true, false]);
    expect(PhotoManager.notifyingOfChange, isFalse);
    await tester.pump(const Duration(seconds: 10));
    expect(manager.calls, 3);
  });
}
