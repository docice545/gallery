import 'dart:async';

/// Owns all Dart work that can touch a background engine's services/database.
/// A cancellation deadline requests cancellation; it never detaches live work
/// with Future.timeout. Resource teardown begins only after every owner drains.
class BackgroundWorkLifecycle {
  final Completer<void> cancellation;
  final Future<void> Function() cancelNativeWork;
  final Future<void> Function() drainCallbacks;
  final Future<void> Function() closeResources;
  final Set<Future<void>> _active = {};
  bool _accepting = true;
  bool _cancelled = false;
  bool _failed = false;
  Future<void>? _nativeCancellation;
  Future<bool>? _completion;

  BackgroundWorkLifecycle({
    required this.cancellation,
    required this.cancelNativeWork,
    required this.drainCallbacks,
    required this.closeResources,
  });

  bool get acceptsWork => _accepting && !cancellation.isCompleted;
  bool get wasCancelled => _cancelled;

  Future<T> track<T>(Future<T> Function() operation) {
    if (!acceptsWork) {
      return Future<T>.error(StateError('Background worker is stopping'));
    }
    final work = Future<T>.sync(operation);
    late final Future<void> drained;
    drained = work
        .then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {
            _failed = true;
          },
        )
        .whenComplete(() {
          _active.remove(drained);
        });
    _active.add(drained);
    return work;
  }

  Future<bool> run(Future<void> Function() operation, {Duration? budget}) async {
    if (!acceptsWork) {
      return false;
    }
    final timer = budget == null ? null : Timer(budget, requestCancellation);
    try {
      await track(operation);
    } catch (_) {
      _failed = true;
    } finally {
      timer?.cancel();
    }
    return finish();
  }

  void requestCancellation() {
    _cancelled = true;
    _stopAccepting();
  }

  Future<bool> cancel() {
    requestCancellation();
    return finish();
  }

  void markFailed() => _failed = true;

  void _stopAccepting() {
    _accepting = false;
    if (!cancellation.isCompleted) {
      cancellation.complete();
    }
    _nativeCancellation ??= Future<void>.sync(cancelNativeWork).catchError((Object _) {
      _failed = true;
    });
  }

  Future<bool> finish() => _completion ??= _finish();

  Future<bool> _finish() async {
    _stopAccepting();
    await _nativeCancellation;
    while (_active.isNotEmpty) {
      await Future.wait(_active.toList());
    }
    try {
      await drainCallbacks();
    } catch (_) {
      _failed = true;
    }
    try {
      await closeResources();
    } catch (_) {
      _failed = true;
    }
    return !_failed && !_cancelled;
  }
}
