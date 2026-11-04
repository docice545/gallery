import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/local_media_refresh.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/app_life_cycle.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:logging/logging.dart';
import 'package:photo_manager/photo_manager.dart';

/// Owned by the signed-in gallery shell, including while a Viewer route is open.
final localMediaRefreshProvider = Provider.autoDispose<void>((ref) {
  if (!CurrentPlatform.isAndroid) {
    return;
  }
  final log = Logger('LocalMediaRefresh');
  final manager = ref.read(backgroundSyncProvider);
  final refresh = LocalMediaRefresh(
    sync: () => manager.syncLocal(enqueue: true),
    onError: (error, stack) => log.warning('Local media refresh failed', error, stack),
  );
  void onChange(MethodCall call) => refresh.notifyChanged();
  PhotoManager.addChangeCallback(onChange);

  // Serialize native registration/unregistration during rapid lifecycle changes.
  var notificationOperation = Future<void>.value();
  var observing = false;
  void setObserving(bool enabled) {
    if (observing == enabled) {
      return;
    }
    observing = enabled;
    notificationOperation = notificationOperation
        .then((_) => enabled ? PhotoManager.startChangeNotify() : PhotoManager.stopChangeNotify())
        .catchError((Object error, StackTrace stack) => log.warning('MediaStore observer failed', error, stack));
  }

  void update() {
    final lifecycle = ref.read(appStateProvider);
    final active =
        ref.read(galleryPermissionNotifier).hasAccess &&
        (lifecycle == AppLifeCycleEnum.active ||
            lifecycle == AppLifeCycleEnum.resumed ||
            lifecycle == AppLifeCycleEnum.inactive);
    setObserving(active);
    refresh.setActive(active);
  }

  ref.listen(appStateProvider, (_, _) => update());
  ref.listen(galleryPermissionNotifier, (_, _) => update());
  ref.onDispose(() {
    refresh.dispose();
    PhotoManager.removeChangeCallback(onChange);
    setObserving(false);
  });
  update();
});
