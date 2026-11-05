import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
// ignore: library_prefixes
import 'package:immich_mobile/entities/store.entity.dart' as dbStore;
import 'package:immich_mobile/providers/infrastructure/cancel.provider.dart';
import 'package:immich_mobile/utils/bootstrap.dart';
import 'package:immich_mobile/wm_executor.dart';
import 'package:logging/logging.dart';
import 'package:worker_manager/worker_manager.dart' show Cancelable;

class InvalidIsolateUsageException implements Exception {
  const InvalidIsolateUsageException();

  @override
  String toString() => "IsolateHelper should only be used from the root isolate";
}

// !! Should be used only from the root isolate
Cancelable<T?> runInIsolateGentle<T>({
  required Future<T> Function(ProviderContainer ref) computation,
  String? debugLabel,
  bool awaitCancellationDrain = false,
  bool dedicated = false,
  int? sqliteRecoveryReleaseEpoch,
}) {
  final token = RootIsolateToken.instance;
  if (token == null) {
    throw const InvalidIsolateUsageException();
  }

  return workerManagerPatch.executeGentle(
    (onCancel) async {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      DartPluginRegistrant.ensureInitialized();

      final log = Logger("IsolateLogger");
      final (dataController, apiService) = await Bootstrap.initDomain(
        shouldBufferLogs: false,
        disableStoreWatching: true,
      );
      final ref = ProviderContainer(
        overrides: [
          cancellationProvider.overrideWithValue(onCancel),
          ...Store.overrideWith(dataController: dataController, apiService: apiService),
        ],
      );

      try {
        // A release epoch is supplied only by the explicit, user-mediated
        // recovery action in BackgroundSyncManager. This lets a reused worker
        // isolate forget its stale process-local gate without auto-clearing a
        // failure when a normal worker starts.
        if (sqliteRecoveryReleaseEpoch != null) {
          SqliteRecoveryGate.clearAfterValidatedRecovery();
        }
        return await computation(ref);
      } catch (error, stack) {
        log.severe("Error in runInIsolateGentle${debugLabel == null ? '' : ' for $debugLabel'}", error, stack);
        // SQLite corruption is a stop condition, not a nullable background
        // result. Preserve the typed signal so BackgroundSync can clear its
        // queue and surface the copy-only recovery requirement to the caller.
        if (error is SqliteDatabaseUnhealthy) {
          rethrow;
        }
        return null;
      } finally {
        ref.dispose();
        await dbStore.Store.dispose();
        await LogService.I.dispose();
        await dataController.close();
      }
    },
    awaitCancellationDrain: awaitCancellationDrain,
    dedicated: dedicated,
  );
}
