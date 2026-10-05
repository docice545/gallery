import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/data_controller.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/services/background_work_lifecycle.dart';
import 'package:immich_mobile/domain/services/hash.service.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/domain/services/sync_stream.service.dart';
// ignore: library_prefixes
import 'package:immich_mobile/entities/store.entity.dart' as dbStore;
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/background_worker_api.g.dart';
import 'package:immich_mobile/platform/background_worker_lock_api.g.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/sync.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/localization.service.dart';
import 'package:immich_mobile/utils/bootstrap.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/wm_executor.dart';
import 'package:logging/logging.dart';

class BackgroundWorkerFgService {
  final BackgroundWorkerFgHostApi _foregroundHostApi;

  const BackgroundWorkerFgService(this._foregroundHostApi);

  // TODO: Move this call to native side once old timeline is removed
  Future<void> enable() => _foregroundHostApi.enable();

  Future<void> saveNotificationMessage(String title, String body) =>
      _foregroundHostApi.saveNotificationMessage(title, body);

  Future<void> configure({int? minimumDelaySeconds, bool? requireCharging}) {
    final backup = SettingsRepository.instance.appConfig.backup;
    return _foregroundHostApi.configure(
      BackgroundWorkerSettings(
        minimumDelaySeconds: minimumDelaySeconds ?? backup.triggerDelay,
        requiresCharging: requireCharging ?? backup.requireCharging,
      ),
    );
  }

  Future<void> disable() => _foregroundHostApi.disable();
}

class BackgroundWorkerBgService extends BackgroundWorkerFlutterApi {
  ProviderContainer? _ref;
  final DataController _dataController;
  final BackgroundWorkerBgHostApi _backgroundHostApi;
  final _cancellationToken = Completer<void>();
  final Logger _logger = Logger('BackgroundWorkerBgService');
  late LocalSyncService _localSyncService;
  late SyncStreamService _remoteSyncService;
  late HashService _hashService;

  bool _isCleanedUp = false;
  late final BackgroundWorkLifecycle _lifecycle;
  BackgroundUploadService? _backgroundUploadService;

  BackgroundWorkerBgService({required this._dataController, required ApiService apiService})
    : _backgroundHostApi = BackgroundWorkerBgHostApi() {
    final ref = ProviderContainer(
      overrides: Store.overrideWith(dataController: _dataController, apiService: apiService),
    );
    _ref = ref;
    try {
      final db = ref.read(driftProvider);
      _localSyncService = LocalSyncService(
        localAlbumRepository: db.localAlbumRepository,
        nativeSyncApi: ref.read(nativeSyncApiProvider),
        trashedLocalAssetRepository: db.trashedLocalAssetRepository,
        assetMediaRepository: ref.read(assetMediaRepositoryProvider),
        permissionRepository: ref.read(permissionRepositoryProvider),
        cancellation: _cancellationToken,
        rethrowErrors: true,
      );
      _remoteSyncService = SyncStreamService(
        syncApiRepository: ref.read(syncApiRepositoryProvider),
        syncStreamRepository: db.syncStreamRepository,
        localAssetRepository: db.localAssetRepository,
        trashedLocalAssetRepository: db.trashedLocalAssetRepository,
        assetMediaRepository: ref.read(assetMediaRepositoryProvider),
        permissionRepository: ref.read(permissionRepositoryProvider),
        syncMigrationRepository: db.syncMigrationRepository,
        api: ref.read(apiServiceProvider),
        cancellation: _cancellationToken,
      );
      _hashService = HashService(
        localAlbumRepository: db.localAlbumRepository,
        localAssetRepository: db.localAssetRepository,
        nativeSyncApi: ref.read(nativeSyncApiProvider),
        trashedLocalAssetRepository: db.trashedLocalAssetRepository,
        cancellation: _cancellationToken,
        rethrowErrors: true,
      );
      _lifecycle = BackgroundWorkLifecycle(
        cancellation: _cancellationToken,
        cancelNativeWork: () async {
          _backgroundUploadService?.stopAcceptingWork();
          await Future.wait([_localSyncService.cancelNativeWork(), _hashService.cancelNativeWork()]);
        },
        drainCallbacks: () async => _backgroundUploadService?.stopAndDrain(),
        closeResources: _handleCleanup,
      );
      BackgroundWorkerFlutterApi.setUp(this);
    } catch (_) {
      ref.dispose();
      _ref = null;
      rethrow;
    }
  }

  bool get _isBackupEnabled => SettingsRepository.instance.appConfig.backup.enabled;

  Future<void> init() async {
    try {
      await _lifecycle.track(
        () => Future.wait(
          [
            loadTranslations(),
            workerManagerPatch.init(dynamicSpawning: true),
            _ref?.read(authServiceProvider).setOpenApiServiceEndpoint(),
            // Initialize the file downloader
            FileDownloader().configure(
              globalConfig: [
                // maxConcurrent: 6, maxConcurrentByHost(server):6, maxConcurrentByGroup: 3
                (Config.holdingQueue, (6, 6, 3)),
                // On Android, if files are larger than 256MB, run in foreground service
                (Config.runInForegroundIfFileLargerThan, 256),
              ],
            ),
            FileDownloader().trackTasksInGroup(kDownloadGroupLivePhoto, markDownloadedComplete: false),
            FileDownloader().trackTasks(),
          ].nonNulls,
        ),
      );

      if (!_lifecycle.acceptsWork) {
        return;
      }
      configureFileDownloaderNotifications();

      // Notify the host that the background worker service has been initialized and is ready to use
      await _backgroundHostApi.onInitialized();
    } catch (error, stack) {
      _logger.severe("Failed to initialize background worker", error, stack);
      _lifecycle.markFailed();
      await _lifecycle.finish();
      await _backgroundHostApi.close();
    }
  }

  @override
  Future<void> onAndroidUpload(int? maxMinutes) async {
    if (!_lifecycle.acceptsWork) {
      return;
    }
    final hashTimeout = Duration(minutes: _isBackupEnabled ? 3 : 6);
    final backupTimeout = maxMinutes != null ? Duration(minutes: maxMinutes - 1) : null;
    await _lifecycle.run(() async {
      await _optimizeDB();
      await _backgroundLoop(
        hashTimeout: hashTimeout,
        backupTimeout: backupTimeout,
        debugLabel: 'Android background upload',
      );
    });
  }

  @override
  Future<bool> onIosUpload(bool isRefresh, int? maxSeconds) async {
    if (!_lifecycle.acceptsWork) {
      return false;
    }
    _logger.info('iOS background upload started');
    final sw = Stopwatch()..start();
    final budget = maxSeconds == null ? null : Duration(seconds: (maxSeconds - 1).clamp(0, maxSeconds));
    final success = await _lifecycle.run(() async {
      if (maxSeconds == null) {
        await _optimizeDB();
      }
      if (!_lifecycle.acceptsWork) {
        return;
      }
      // Future.wait drains all phases even if one fails. No timeout future may
      // outlive its owner and continue accessing sqlite after teardown.
      await Future.wait<void>([
        _localSyncService.sync(),
        _remoteSyncService.sync().then((success) {
          if (!success) {
            throw StateError('Background remote sync failed');
          }
        }),
        _hashService.hashAssets(),
        _handleBackup(),
      ]);
    }, budget: budget);
    sw.stop();
    _logger.info('iOS background upload drained in ${sw.elapsed.inSeconds}s, success: $success');
    return success;
  }

  Future<void> _backgroundLoop({
    required Duration hashTimeout,
    required Duration? backupTimeout,
    required String debugLabel,
  }) async {
    _logger.info(
      '$debugLabel started hashTimeout: ${hashTimeout.inSeconds}s, backupTimeout: ${backupTimeout?.inMinutes ?? '~'}m',
    );
    final sw = Stopwatch()..start();
    try {
      if (!await _syncAssets(hashTimeout: hashTimeout)) {
        _logger.warning("Remote sync did not complete successfully, skipping backup");
        return;
      }

      final backupFuture = _handleBackup();
      Timer? cancelTimer;
      if (backupTimeout != null) {
        cancelTimer = Timer(backupTimeout, () {
          if (!_cancellationToken.isCompleted) {
            _logger.warning("$debugLabel timed out after ${backupTimeout.inMinutes}m, cancelling backup");
            _cancellationToken.complete();
          }
        });
      }
      try {
        await backupFuture;
      } finally {
        cancelTimer?.cancel();
      }
    } catch (error, stack) {
      _logger.severe("Failed to complete $debugLabel", error, stack);
    } finally {
      sw.stop();
      _logger.info("$debugLabel completed in ${sw.elapsed.inSeconds}s");
    }
  }

  @override
  Future<void> cancel() async {
    _logger.warning('Background worker cancellation requested');
    await _lifecycle.cancel();
  }

  Future<void> _optimizeDB() async {
    try {
      await (_dataController.db.optimize(allTables: true), _dataController.logDb.optimize()).wait;
    } catch (error, stack) {
      dPrint(() => "Error during background worker optimize: $error, $stack");
    }
  }

  Future<void> _handleCleanup() async {
    // If ref is null, it means the service was never initialized properly
    if (_isCleanedUp || _ref == null) {
      return;
    }

    _isCleanedUp = true;
    _logger.info('Cleaning up background worker');
    Object? failure;
    StackTrace? failureStack;
    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }

    await attempt(() => workerManagerPatch.dispose());
    await attempt(() async => Future.wait([LogService.I.dispose(), dbStore.Store.dispose()]));
    await attempt(_dataController.close);
    _ref?.dispose();
    _ref = null;
    if (failure != null) {
      Error.throwWithStackTrace(failure!, failureStack!);
    }
  }

  Future<void> _handleBackup() async {
    if (!_lifecycle.acceptsWork || !_isBackupEnabled) {
      return;
    }
    final currentUser = _ref?.read(currentUserProvider);
    if (currentUser == null) {
      throw StateError('Background backup requires a current user');
    }
    if (Platform.isIOS) {
      _backgroundUploadService = _ref!.read(backgroundUploadServiceProvider);
      await _ref!
          .read(backupProvider.notifier)
          .startBackupWithURLSession(currentUser.id, cancellation: _cancellationToken);
    } else {
      await _ref!
          .read(foregroundUploadServiceProvider)
          .uploadCandidates(currentUser.id, _cancellationToken, useSequentialUpload: true);
    }
  }

  Future<bool> _syncAssets({Duration? hashTimeout}) async {
    await _localSyncService.sync();
    if (_isCleanedUp) {
      return false;
    }

    final isSuccess = await _remoteSyncService.sync();
    if (_isCleanedUp) {
      return isSuccess;
    }

    var hashFuture = _lifecycle.track(_hashService.hashAssets);
    if (hashTimeout != null) {
      hashFuture = hashFuture.timeout(
        hashTimeout,
        onTimeout: () {
          // Consume cancellation errors as we want to continue processing
        },
      );
    }

    await hashFuture;
    return isSuccess;
  }
}

class BackgroundWorkerLockService {
  final BackgroundWorkerLockApi _hostApi;
  const BackgroundWorkerLockService(this._hostApi);

  Future<void> lock() async {
    if (CurrentPlatform.isAndroid) {
      return _hostApi.lock();
    }
  }

  Future<void> unlock() async {
    if (CurrentPlatform.isAndroid) {
      return _hostApi.unlock();
    }
  }
}

/// Native entry invoked from the background worker. If renaming or moving this to a different
/// library, make sure to update the entry points and URI in native workers as well
@pragma('vm:entry-point')
Future<void> backgroundSyncNativeEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  DataController? controller;
  BackgroundWorkerBgService? worker;
  try {
    final (dataController, apiService) = await Bootstrap.initDomain(
      shouldBufferLogs: false,
      disableStoreWatching: true,
    );
    controller = dataController;
    worker = BackgroundWorkerBgService(dataController: dataController, apiService: apiService);
    await worker.init();
  } catch (_) {
    // Bootstrap owns partial initialization. If provider/worker construction
    // failed after bootstrap returned, this entrypoint still owns that DB.
    try {
      if (worker != null) {
        await worker.cancel();
      } else if (controller != null) {
        try {
          await Future.wait([LogService.I.dispose(), dbStore.Store.dispose()]);
        } finally {
          await controller.close();
        }
      }
    } finally {
      // Explicit bootstrap-failure acknowledgement, not a missing-channel guess.
      await BackgroundWorkerBgHostApi().close();
    }
  }
}
