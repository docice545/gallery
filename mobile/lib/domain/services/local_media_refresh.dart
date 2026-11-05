import 'dart:async';

/// Coalesces MediaStore notifications; never polls and never reloads the screen.
/// Changes received during a sync are drained in one subsequent delta pass.
class LocalMediaRefresh {
  LocalMediaRefresh({required this.sync, required this.onError});

  final Future<void> Function() sync;
  final void Function(Object, StackTrace) onError;
  Timer? _timer;
  bool _active = false;
  bool _dirty = false;
  bool _running = false;
  bool _disposed = false;

  void setActive(bool active) {
    if (_disposed || active == _active) {
      return;
    }
    _active = active;
    if (active) {
      // The observer may have been stopped while the app was in the background.
      notifyChanged();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void notifyChanged() {
    if (_disposed) {
      return;
    }
    _dirty = true;
    _schedule();
  }

  void _schedule() {
    if (!_active || _running || _timer != null || !_dirty || _disposed) {
      return;
    }
    // A bounded coalescing window, not a trailing debounce that can starve
    // during a long camera burst. No timer remains when the queue is empty.
    _timer = Timer(const Duration(milliseconds: 350), () {
      _timer = null;
      unawaited(_drain());
    });
  }

  Future<void> _drain() async {
    if (!_active || _disposed) {
      return;
    }
    _dirty = false;
    _running = true;
    try {
      await sync();
    } catch (error, stack) {
      onError(error, stack);
      // Retry on the next notification/resume, not a battery-draining loop.
    } finally {
      _running = false;
      _schedule();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
