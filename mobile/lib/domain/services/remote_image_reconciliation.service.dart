import 'dart:async';

import 'package:immich_mobile/domain/models/remote_image_http_exception.dart';
import 'package:logging/logging.dart';

/// HTTP 400/404 are ambiguous: authorization and missing derivatives use these
/// statuses too. Only an authenticated deletion receipt can retire a cached row.
class RemoteImageReconciliationService {
  RemoteImageReconciliationService({
    required this.endpoint,
    this.mediaEndpoint,
    this.currentEndpoint,
    required this.isCurrentSession,
    required this.isDeletionComplete,
    required this.retireDeletedAsset,
    required this.syncIncrementally,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Uri endpoint;
  final Uri? mediaEndpoint;
  final Uri Function()? currentEndpoint;
  final bool Function() isCurrentSession;
  final Future<bool> Function(String id) isDeletionComplete;
  final Future<bool> Function(String id) retireDeletedAsset;
  final Future<void> Function() syncIncrementally;
  final DateTime Function() _now;
  static final _log = Logger('RemoteImageReconciliation');
  static final _uuid = RegExp(r'^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$');
  final _pending = <String, Future<bool>>{};
  final _recent = <String, ({DateTime at, bool deleted})>{};
  Future<void> _tail = Future<void>.value();
  DateTime? _lastSync;

  /// Returns true only after the durable remote-cache transaction committed.
  /// No timer retries: re-rendering a failed tile is rate limited for 30 seconds.
  Future<bool> reconcile(RemoteImageHttpException error, String requestUri) {
    final id = error.assetId;
    final request = Uri.tryParse(requestUri);
    if (!isCurrentSession() ||
        !const {400, 404}.contains(error.statusCode) ||
        id == null ||
        !_uuid.hasMatch(id) ||
        request == null ||
        !const {'http', 'https'}.contains(request.scheme) ||
        !request.hasAuthority ||
        request.path != error.requestPath ||
        !_matchesCurrentEndpoint(request, id)) {
      return Future.value(false);
    }
    final active = _pending[id];
    if (active != null) {
      return active;
    }
    final recent = _recent[id];
    if (recent != null && _now().difference(recent.at) < const Duration(seconds: 30)) {
      return Future.value(recent.deleted);
    }
    // Scrolling through stale rows must not create an unbounded HTTP backlog.
    if (_pending.length >= 32) {
      return Future.value(false);
    }
    final result = _tail.then((_) => _reconcile(id));
    _pending[id] = result;
    _tail = result.then<void>((_) {});
    return result;
  }

  bool _matchesCurrentEndpoint(Uri request, String id) {
    // ApiService's route can change in place when Wi-Fi changes. Validate the
    // current authenticated route at call time rather than pinning its origin
    // for the entire provider lifetime; the library/account guards are separate.
    for (final candidate in [currentEndpoint?.call() ?? endpoint, ?mediaEndpoint]) {
      if (!const {'http', 'https'}.contains(candidate.scheme) || !candidate.hasAuthority) {
        continue;
      }
      final basePath = candidate.path.replaceFirst(RegExp(r'/$'), '');
      if (request.origin == candidate.origin &&
          {'$basePath/assets/$id/thumbnail', '$basePath/assets/$id/original'}.contains(request.path)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _reconcile(String id) async {
    var deleted = false;
    try {
      if (!isCurrentSession()) {
        return false;
      }
      final complete = await isDeletionComplete(id);
      if (!isCurrentSession()) {
        return false;
      }
      if (complete) {
        deleted = await retireDeletedAsset(id);
        if (deleted) {
          _log.info('Retired remote cache after confirmed deletion: asset=$id');
        }
      } else {
        // Reuse the normal incremental stream/checkpoint. Never reset ACKs,
        // trigger a full scan, or infer deletion from an access-denied response.
        final now = _now();
        if (_lastSync == null || now.difference(_lastSync!) >= const Duration(seconds: 30)) {
          _lastSync = now;
          await syncIncrementally();
        }
      }
      return deleted;
    } catch (error, stack) {
      _log.warning('Unable to reconcile remote image: asset=$id', error, stack);
      return false;
    } finally {
      unawaited(_pending.remove(id));
      _recent.remove(id);
      _recent[id] = (at: _now(), deleted: deleted);
      while (_recent.length > 256) {
        _recent.remove(_recent.keys.first);
      }
    }
  }
}
