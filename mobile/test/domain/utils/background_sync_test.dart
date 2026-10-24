import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:worker_manager/worker_manager.dart';

class _FakeBackgroundSyncManager extends BackgroundSyncManager {
  final List<String> calls = [];
  final Completer<bool> remoteCompleter = Completer<bool>();

  @override
  Future<bool> syncRemote({bool enqueue = false}) {
    calls.add('remote-start');
    return remoteCompleter.future.then((success) {
      calls.add('remote-complete');
      return success;
    });
  }

  @override
  Future<void> syncLocal({bool full = false}) async {
    calls.add('local-full-$full');
  }
}

class _ControlledBackgroundSyncManager extends BackgroundSyncManager {
  final local = Completer<void>();
  final remote = Completer<bool?>();
  final trash = <Completer<void>>[];
  int cancelledTrash = 0;

  @override
  Cancelable<void> createLocalSyncTask(bool full) => Cancelable(
    completer: local,
    onCancel: () {
      if (!local.isCompleted) {
        local.completeError(CanceledError());
      }
    },
  );

  @override
  Cancelable<bool?> createRemoteSyncTask() => Cancelable(
    completer: remote,
    onCancel: () {
      if (!remote.isCompleted) {
        remote.completeError(CanceledError());
      }
    },
  );

  @override
  Cancelable<void> createDeviceTrashTask() {
    final result = Completer<void>();
    trash.add(result);
    // Model the draining cancellation contract: signalling cancellation does
    // not complete an operation which still owns a native/DB continuation.
    return Cancelable(completer: result, onCancel: () => cancelledTrash++);
  }
}

void main() {
  test('syncRemoteThenLocal defers full local sync until remote sync has completed', () async {
    final manager = _FakeBackgroundSyncManager();

    final result = manager.syncRemoteThenLocal(
      fullLocalSync: true,
      delay: (duration) async {
        manager.calls.add('delay-${duration.inMilliseconds}');
      },
    );

    expect(manager.calls, ['remote-start']);

    manager.remoteCompleter.complete(true);

    expect(await result.remoteSync, isTrue);
    await result.deferredLocalSync;

    expect(manager.calls, ['remote-start', 'remote-complete', 'delay-1500', 'local-full-true']);
  });

  test('unresolved Android trash cannot gate local sync completion or the next upload', () async {
    final manager = _ControlledBackgroundSyncManager();
    final events = <String>[];
    final synced = manager.syncLocal();
    final upload = synced.then((_) => events.add('upload-started'));
    manager.local.complete();
    await upload.timeout(const Duration(seconds: 2));

    expect(events, ['upload-started']);
    expect(manager.trash, hasLength(1));
    expect(manager.trash.single.isCompleted, isFalse);
    manager.trash.single.complete();
    await manager.cancel();
  });

  test('unresolved Android trash cannot gate remote sync completion', () async {
    final manager = _ControlledBackgroundSyncManager();
    final synced = manager.syncRemote();
    manager.remote.complete(true);
    expect(await synced.timeout(const Duration(seconds: 2)), isTrue);
    expect(manager.trash, hasLength(1));
    expect(manager.trash.single.isCompleted, isFalse);
    manager.trash.single.complete();
    await manager.cancel();
  });

  test('concurrent sync completions share one maintenance pass and resume cancellation drains it', () async {
    final manager = _ControlledBackgroundSyncManager();
    final local = manager.syncLocal();
    final remote = manager.syncRemote();
    manager.local.complete();
    manager.remote.complete(true);
    await Future.wait([local, remote]);
    expect(manager.trash, hasLength(1));

    var drained = false;
    final stopping = manager.cancelResumeSyncs().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(manager.cancelledTrash, 1);
    expect(drained, isFalse, reason: 'resume teardown must wait for its maintenance owner');
    manager.trash.single.complete();
    await stopping;
    expect(drained, isTrue);
  });

  test('a cancelled sync completion cannot start new device-trash work', () async {
    final manager = _ControlledBackgroundSyncManager();
    final syncing = manager.syncLocal();
    await manager.cancelResumeSyncs();
    await syncing;
    expect(manager.trash, isEmpty);
  });

  test('an old draining task cannot clear a replacement maintenance owner', () async {
    final manager = _ControlledBackgroundSyncManager();
    final first = manager.syncDeviceTrash();
    final stopping = manager.cancelResumeSyncs();
    final replacement = manager.syncDeviceTrash();
    expect(manager.trash, hasLength(2));
    manager.trash.first.complete();
    await Future.wait([first, stopping]);
    final deduped = manager.syncDeviceTrash();
    expect(manager.trash, hasLength(2));
    manager.trash.last.complete();
    await Future.wait([replacement, deduped]);
    await manager.cancel();
  });
}
