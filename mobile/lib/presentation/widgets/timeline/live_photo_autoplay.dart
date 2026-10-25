import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

const livePhotoVisibilityThreshold = 0.8;
const livePhotoSettlingDelay = Duration(milliseconds: 350);
const livePhotoMinimumViewportChange = 96.0;
const livePhotoViewportChangeFraction = 0.25;

double livePhotoViewportChangeThreshold(double viewportExtent) =>
    math.max(livePhotoMinimumViewportChange, viewportExtent * livePhotoViewportChangeFraction);

double livePhotoVisibleFraction(Rect tile, Rect viewport) {
  if (tile.isEmpty || viewport.isEmpty || !tile.overlaps(viewport)) {
    return 0;
  }
  final intersection = tile.intersect(viewport);
  return (intersection.width * intersection.height / (tile.width * tile.height)).clamp(0, 1);
}

class LivePhotoCandidate {
  const LivePhotoCandidate({
    required this.token,
    required this.asset,
    required this.visibleFraction,
    required this.distanceFromCenter,
    this.localVideoPath,
  });

  final Object token;
  final BaseAsset asset;
  final double visibleFraction;
  final double distanceFromCenter;

  /// The locally resolved video component, not the still or a remote fallback.
  /// The scope proves availability before supplying the same path to the player.
  final String? localVideoPath;
}

bool _isLocalVideoPath(String? path) {
  if (path == null || path.trim().isEmpty) {
    return false;
  }
  final uri = Uri.tryParse(path);
  if (uri == null) {
    return false;
  }
  if (uri.scheme.isEmpty) {
    return !uri.hasAuthority;
  }
  return uri.scheme == 'file' &&
      (uri.host.isEmpty || uri.host == 'localhost') &&
      uri.path.isNotEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

/// Keep the active tile while it remains visible; otherwise prefer the most
/// visible motion photo closest to the viewport centre. Static photos and videos
/// never qualify, even if a malformed video carries a live-photo relation.
/// A local still/merged relation alone is insufficient: the scope must have
/// resolved its local video component. Server sources never qualify.
LivePhotoCandidate? chooseLivePhotoCandidate(Iterable<LivePhotoCandidate> candidates, {Object? activeToken}) {
  LivePhotoCandidate? best;
  for (final candidate in candidates) {
    if (!candidate.asset.isImage ||
        !candidate.asset.isMotionPhoto ||
        candidate.asset.storage == AssetState.remote ||
        (candidate.asset.localId?.isEmpty ?? true) ||
        !_isLocalVideoPath(candidate.localVideoPath) ||
        candidate.visibleFraction < livePhotoVisibilityThreshold ||
        !candidate.visibleFraction.isFinite ||
        !candidate.distanceFromCenter.isFinite) {
      continue;
    }
    if (candidate.token == activeToken) {
      return candidate;
    }
    if (best == null ||
        candidate.visibleFraction > best.visibleFraction ||
        (candidate.visibleFraction == best.visibleFraction && candidate.distanceFromCenter < best.distanceFromCenter)) {
      best = candidate;
    }
  }
  return best;
}

/// One playback lease for the main timeline. No player, source or video download
/// is created until the settling timer grants this lease to a registered tile.
class LivePhotoAutoplayController extends ChangeNotifier {
  LivePhotoAutoplayController({bool enabled = true}) {
    _enabled = enabled;
  }

  bool _enabled = true;
  bool _scrolling = false;
  bool _disposed = false;
  double? _scrollOffset;
  double? _viewportExtent;
  double? _lastPlayedViewportExtent;
  double _scrollDisplacementSincePlayback = 0;
  BaseAsset? _lastPlayedAsset;
  List<LivePhotoCandidate> _candidates = const [];
  Object? _activeToken;
  LivePhotoCandidate? _activeCandidate;
  bool _activeStarted = false;
  BaseAsset? _retryAsset;
  bool _retryUsed = false;
  Object? _pendingToken;
  Timer? _timer;
  int _leaseRevision = 0;

  Object? get activeToken => _activeToken;
  int get leaseRevision => _leaseRevision;

  /// A real return to the feed grants one new settled playback, without
  /// turning ordinary gestures, selection or settings toggles into loops.
  void startFeedActivation() {
    if (_disposed) {
      return;
    }
    _stop();
    _lastPlayedAsset = null;
    _lastPlayedViewportExtent = null;
    _scrollDisplacementSincePlayback = 0;
    _retryAsset = null;
    _retryUsed = false;
    _schedule();
  }

  void setEnabled(bool enabled) {
    if (_enabled == enabled || _disposed) {
      return;
    }
    _enabled = enabled;
    if (!enabled) {
      _stop();
    } else {
      _schedule();
    }
  }

  /// Stop on every scroll/gesture, including slow drags and scrubber jumps.
  /// This also prevents decoder work from competing with a fling.
  void setScrolling(bool scrolling) {
    if (_disposed) {
      return;
    }
    _scrolling = scrolling;
    if (scrolling) {
      _stop();
    } else {
      _schedule();
    }
  }

  /// Position is relative to the last playback, not the last scroll event.
  /// Small drags may accumulate into a new viewport, but a fling out and back,
  /// a tap or settings toggle cannot rearm the same region. Actual feed
  /// reactivation starts a new one-shot budget through startFeedActivation.
  void updateViewport({required double scrollOffset, required double viewportExtent, bool fromScroll = true}) {
    if (_disposed || !scrollOffset.isFinite || !viewportExtent.isFinite || viewportExtent <= 0) {
      return;
    }
    final previousOffset = _scrollOffset;
    if (fromScroll && previousOffset != null && _lastPlayedAsset != null) {
      _scrollDisplacementSincePlayback += scrollOffset - previousOffset;
    }
    _scrollOffset = scrollOffset;
    _viewportExtent = viewportExtent;
  }

  void updateCandidates(List<LivePhotoCandidate> candidates) {
    if (_disposed) {
      return;
    }
    _candidates = candidates;
    if (_activeToken != null &&
        chooseLivePhotoCandidate(candidates, activeToken: _activeToken)?.token != _activeToken) {
      _stop();
    }
    _schedule();
  }

  void unregister(Object token) {
    updateCandidates(_candidates.where((candidate) => candidate.token != token).toList());
  }

  /// A reservation is not playback: only native position progress consumes the
  /// one-shot budget. Cancellation before that can retry after settling.
  void started(Object token) {
    if (!_disposed && _activeToken == token && !_activeStarted) {
      _activeStarted = true;
      _consumeActive();
    }
  }

  /// Completion or a permanent rejection consumes the viewport even when no
  /// frame could be shown. Never cascade through its other photos.
  void complete(Object token) {
    if (!_disposed && _activeToken == token) {
      if (!_activeStarted) {
        _consumeActive();
      }
      _stop();
    }
  }

  /// Allow one settled retry of the same source for a cold load/play failure.
  /// A second failure or a failure after frames started consumes the viewport.
  void failed(Object token) {
    if (_disposed || _activeToken != token) {
      return;
    }
    if (_activeStarted || _retryUsed) {
      complete(token);
      return;
    }
    final asset = _activeCandidate!.asset;
    _consumeActive();
    _retryAsset = asset;
    _stop();
    _schedule();
  }

  void _consumeActive() {
    _lastPlayedViewportExtent = _viewportExtent;
    _scrollDisplacementSincePlayback = 0;
    _lastPlayedAsset = _activeCandidate!.asset;
    _retryAsset = null;
    _retryUsed = false;
  }

  void _schedule() {
    if (!_enabled || _scrolling || _disposed || _activeToken != null) {
      return;
    }
    final candidate = chooseLivePhotoCandidate(_candidates);
    if (candidate == null || !_canPlayInViewport(candidate)) {
      _timer?.cancel();
      _pendingToken = null;
      return;
    }
    if (_pendingToken == candidate.token && (_timer?.isActive ?? false)) {
      return;
    }
    _timer?.cancel();
    _pendingToken = candidate.token;
    _timer = Timer(livePhotoSettlingDelay, () {
      _pendingToken = null;
      if (_disposed || !_enabled || _scrolling) {
        return;
      }
      final current = chooseLivePhotoCandidate(_candidates);
      if (current?.token != candidate.token || !_canPlayInViewport(current!)) {
        _schedule();
        return;
      }
      _retryUsed = _retryAsset != null && current.asset.refersToSameAsset(_retryAsset!);
      _retryAsset = null;
      _activeCandidate = current;
      _activeStarted = false;
      _activeToken = candidate.token;
      _leaseRevision++;
      notifyListeners();
    });
  }

  bool _canPlayInViewport(LivePhotoCandidate candidate) {
    if (_retryAsset != null && candidate.asset.refersToSameAsset(_retryAsset!)) {
      return true;
    }
    final previousAsset = _lastPlayedAsset;
    if (previousAsset == null) {
      return true;
    }
    final previousExtent = _lastPlayedViewportExtent;
    if (previousExtent == null) {
      return false;
    }
    return _scrollDisplacementSincePlayback.abs() >= livePhotoViewportChangeThreshold(previousExtent) &&
        !candidate.asset.refersToSameAsset(previousAsset);
  }

  void _stop() {
    _timer?.cancel();
    _pendingToken = null;
    if (_activeToken != null) {
      if (!_activeStarted && _retryUsed) {
        // Cancellation is not the retry's failure. Resume the remaining attempt
        // after a route/gesture suspension, without resetting its failure budget.
        _retryAsset = _activeCandidate!.asset;
        _retryUsed = false;
      }
      _activeToken = null;
      _activeCandidate = null;
      _activeStarted = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _candidates = const [];
    _activeToken = null;
    _activeCandidate = null;
    _lastPlayedAsset = null;
    _retryAsset = null;
    super.dispose();
  }
}
