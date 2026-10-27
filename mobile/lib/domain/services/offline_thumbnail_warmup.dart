import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart';
import 'package:ffi/ffi.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

/// Warms FOTO's durable native thumbnail cache from the already-synced Drift
/// catalog. Does not download originals, write to Drift, or enqueue uploads.
/// Runs only while the Photos screen is mounted and Wi-Fi is connected.
class OfflineThumbnailWarmup {
  static final _log = Logger('OfflineThumbnailWarmup');
  static const _pageSize = 40;
  static const _requestTimeout = Duration(seconds: 12);
  static const _pause = Duration(milliseconds: 30);

  int _nextRequestId = -1; // ImageRequest reserves non-negative IDs.
  int? _activeRequestId;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    final id = _activeRequestId;
    if (id != null) {
      unawaited(remoteImageApi.cancelRequest(id));
    }
  }

  Future<void> run({
    required Drift db,
    required List<String> ownerIds,
    required bool Function() sessionIsCurrent,
  }) async {
    if (!Platform.isAndroid || ownerIds.isEmpty || !sessionIsCurrent()) return;

    String? afterId;
    var consecutiveFailures = 0;
    var successful = 0;

    while (!_cancelled && sessionIsCurrent()) {
      final transports = await Connectivity().checkConnectivity();
      // Never silently prefetch a large library on cellular/mobile data.
      if (!transports.contains(ConnectivityResult.wifi)) return;

      final query = db.select(db.remoteAssetEntity)
        ..where(
          (row) =>
              row.ownerId.isIn(ownerIds) &
              row.deletedAt.isNull() &
              row.isIndexTombstone.equals(false) &
              row.visibility.equals(AssetVisibility.timeline.index) &
              row.thumbHash.isNotNull() &
              (afterId == null ? const Constant(true) : row.id.isBiggerThanValue(afterId!)),
        )
        ..orderBy([(row) => OrderingTerm.asc(row.id)])
        ..limit(_pageSize);

      // Cursor pagination avoids buffering the full archive in RAM.
      final page = await query.get();
      if (page.isEmpty) break;

      for (final asset in page) {
        if (_cancelled || !sessionIsCurrent()) return;
        final hash = asset.thumbHash;
        if (hash == null || hash.isEmpty) continue;

        final id = _nextRequestId--;
        _activeRequestId = id;
        try {
          final url = getThumbnailUrlForRemoteId(
            asset.id,
            type: AssetMediaSize.thumbnail,
            edited: true,
            thumbhash: hash,
          );
          // preferEncoded avoids expensive bitmap decode. The Kotlin image
          // fetcher saves the encoded thumbnail to filesDir on success.
          final result = await remoteImageApi
              .requestImage(url, requestId: id, preferEncoded: true, width: null, height: null)
              .timeout(_requestTimeout);

          final pointer = result?['pointer'];
          if (pointer != null && pointer != 0) {
            // requestImage transfers malloc ownership to the Dart caller.
            malloc.free(Pointer<Uint8>.fromAddress(pointer));
          }
          successful++;
          consecutiveFailures = 0;
        } on TimeoutException {
          unawaited(remoteImageApi.cancelRequest(id));
          consecutiveFailures++;
        } catch (error) {
          _log.fine('Offline thumbnail preload skipped a remote image', error);
          consecutiveFailures++;
        } finally {
          if (_activeRequestId == id) _activeRequestId = null;
        }
        // Stop a disconnected or unauthorized preload rather than retrying
        // thousands of failed requests while offline.
        if (consecutiveFailures >= 3) return;
        if (_cancelled || !sessionIsCurrent()) return;
        await Future<void>.delayed(_pause);
      }
      afterId = page.last.id;
    }

    _log.fine('Offline thumbnail warmup completed: $successful image requests');
  }
}
