import 'dart:async';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:logging/logging.dart';

/// Executes durable device-trash intents independently of sync checkpoints.
///
/// A server ACK means that the intent is durable, not that Android has accepted
/// the mutation. Only a verified MediaStore result completes an intent.
class LocalTrashSyncService {
  final TrashedLocalAssetRepository _repository;
  final AssetMediaRepository _mediaRepository;
  final DevicePermissionRepository _permissionRepository;
  final DateTime Function() _clock;
  final Completer<void>? _cancellation;
  final _log = Logger('LocalTrashSyncService');

  LocalTrashSyncService({
    required this._repository,
    required this._mediaRepository,
    required this._permissionRepository,
    this._cancellation,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.timestamp;

  Future<void> runIfEnabled() async {
    if (CurrentPlatform.isAndroid && Store.get(StoreKey.manageLocalMediaAndroid, false)) {
      await drain();
    }
  }

  Future<void> drain({bool? hasPermission}) async {
    if (_cancellation?.isCompleted ?? false) {
      return;
    }
    final granted = hasPermission ?? await _permissionRepository.hasManageMediaPermission();
    final restored = await _repository.updateManageMediaPermission(granted);
    if (restored) {
      await _repository.clearPermissionHashFailures();
      await _repository.retryPermissionBlockedTrash(now: _clock());
    }
    if (!granted) {
      _log.warning('Device trash deferred: MANAGE_MEDIA is missing; durable intents retained');
      return;
    }

    // One bounded pass per sync. The database lease also coordinates the local
    // and remote engines; failures retain their own persistent retry deadline.
    final pending = await _repository.claimPendingTrash(now: _clock(), limit: 32);
    if (pending.isEmpty) {
      return;
    }
    if (_cancellation?.isCompleted ?? false) {
      // No Android operation started. Its durable lease will become eligible
      // after restart; do not release another engine's claim during teardown.
      return;
    }
    final outcomes = await (() async {
      try {
        final assets = pending.map((item) => item.asset).toList();
        return await (_cancellation == null
            ? _mediaRepository.trashForSync(assets)
            : _mediaRepository.trashForSync(assets, cancellation: _cancellation.future));
      } catch (error, stack) {
        final code = error is PlatformException ? error.code : 'platformError';
        final message = error is PlatformException
            ? '${error.message ?? error.code}; details=${error.details}'
            : error.toString();
        for (final item in pending) {
          await _repository.failPendingTrash(item, code, message, now: _clock());
        }
        _log.warning('Device trash failed; ${pending.length} intents retained for a later retry', error, stack);
        return null;
      }
    })();
    if (outcomes == null) {
      return;
    }
    for (final item in pending) {
      final outcome = outcomes[item.asset.id];
      if (outcome?.isTrashed == true) {
        await _repository.completePendingTrash(item);
      } else {
        final code = outcome?.code ?? 'invalidResponse';
        final message = outcome?.message ?? 'Android did not verify that this asset is in trash';
        await _repository.failPendingTrash(item, code, message, now: _clock());
        _log.warning('Device trash deferred for ${item.asset.id}: $code ($message)');
      }
    }
  }
}
