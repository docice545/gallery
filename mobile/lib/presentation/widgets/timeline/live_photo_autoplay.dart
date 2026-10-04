import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

const livePhotoVisibilityThreshold = 0.8;
const livePhotoSettlingDelay = Duration(milliseconds: 350);

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
  });

  final Object token;
  final BaseAsset asset;
  final double visibleFraction;
  final double distanceFromCenter;
}

/// Keep the active tile while it remains visible; otherwise prefer the most
/// visible motion photo closest to the viewport centre. Static photos and videos
/// never qualify, even if a malformed video carries a live-photo relation.
LivePhotoCandidate? chooseLivePhotoCandidate(Iterable<LivePhotoCandidate> candidates, {Object? activeToken}) {
  LivePhotoCandidate? best;
  for (final candidate in candidates) {
    if (!candidate.asset.isImage ||
        !candidate.asset.isMotionPhoto ||
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
  bool _playedThisSettling = false;
  List<LivePhotoCandidate> _candidates = const [];
  Object? _activeToken;
  Object? _pendingToken;
  Timer? _timer;

  Object? get activeToken => _activeToken;

  void setEnabled(bool enabled) {
    if (_enabled == enabled || _disposed) {
      return;
    }
    _enabled = enabled;
    _playedThisSettling = false;
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
      _playedThisSettling = false;
      _stop();
    } else {
      _schedule();
    }
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

  /// Play once per settled viewport. Completion/errors restore the photo and
  /// do not walk through every visible motion photo or retry a broken source.
  void complete(Object token) {
    if (!_disposed && _activeToken == token) {
      _stop();
    }
  }

  void _schedule() {
    if (!_enabled || _scrolling || _playedThisSettling || _disposed || _activeToken != null) {
      return;
    }
    final candidate = chooseLivePhotoCandidate(_candidates);
    if (candidate == null) {
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
      if (current?.token != candidate.token) {
        _schedule();
        return;
      }
      _playedThisSettling = true;
      _activeToken = candidate.token;
      notifyListeners();
    });
  }

  void _stop() {
    _timer?.cancel();
    _pendingToken = null;
    if (_activeToken != null) {
      _activeToken = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _candidates = const [];
    _activeToken = null;
    super.dispose();
  }
}
