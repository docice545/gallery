import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
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

class _QueuedRemoteSyncManager extends BackgroundSyncManager {
  final runs = <Completer<bool?>>[];
  int localRequests = 0;
  int hashRequests = 0;

  _QueuedRemoteSyncManager({super.onRemoteSyncComplete, super.onRemoteSyncError});

  @override
  Cancelable<bool?> createRemoteSyncTask() {
    final result = Completer<bool?>();
    runs.add(result);
    return Cancelable(
      completer: result,
      onCancel: () {
        if (!result.isCompleted) {
          result.completeError(CanceledError());
        }
      },
    );
  }

  @override
  Future<void> syncDeviceTrash() async {}

  @override
  Future<void> syncLocal({bool full = false}) async => localRequests++;

  @override
  Future<void> hashAssets({bool enqueue = false}) async => hashRequests++;
}

class _ControlledHashManager extends BackgroundSyncManager {
  _ControlledHashManager({super.onHashingError, this.drainOnCancel = false});

  final bool drainOnCancel;
  final catalog = <String>{'older-photo'};
  final hashed = <String>{};
  final snapshots = <Set<String>>[];
  final runs = <Completer<void>>[];
  int cancellations = 0;

  @override
  Cancelable<void> createHashTask() {
    final result = Completer<void>();
    runs.add(result);
    // HashService obtains its album/candidate list once for each pass.
    snapshots.add(Set.of(catalog));
    return Cancelable(
      completer: result,
      onCancel: () {
        cancellations++;
        if (!drainOnCancel && !result.isCompleted) {
          result.completeError(CanceledError());
        }
      },
    );
  }

  void finish(int index) {
    hashed.addAll(snapshots[index]);
    runs[index].complete();
  }
}

void main() {
  group('saved-copy hashing after an older snapshot', () {
    test('coalesces editor requests and awaits the follow-up that includes each saved copy', () async {
      final manager = _ControlledHashManager();
      final existing = manager.hashAssets();
      manager.catalog.add('edited-copy');
      var importedCopiesReadyForBackup = false;
      final refreshes = [for (var i = 0; i < 4; i++) manager.hashAssets(enqueue: true)];
      final waiting = Future.wait(refreshes).then((_) => importedCopiesReadyForBackup = true);

      expect(manager.snapshots, [
        {'older-photo'},
      ]);
      manager.finish(0);
      await existing;
      expect(manager.runs, hasLength(2));
      expect(manager.hashed, {'older-photo'});
      expect(importedCopiesReadyForBackup, isFalse);
      expect(manager.snapshots.last, {'older-photo', 'edited-copy'});

      manager.finish(1);
      await waiting;
      expect(importedCopiesReadyForBackup, isTrue);
      expect(manager.hashed, contains('edited-copy'));
      expect(manager.runs, hasLength(2));
      await manager.cancel();
    });

    test('an idle enqueue starts one pass and normal concurrent callers do not request another', () async {
      final manager = _ControlledHashManager();
      final saved = manager.hashAssets(enqueue: true);
      final existing = manager.hashAssets();
      expect(manager.runs, hasLength(1));
      manager.finish(0);
      await Future.wait([saved, existing]);
      expect(manager.runs, hasLength(1));
      await manager.cancel();
    });

    test('a copy saved during the follow-up waits for one further shared pass', () async {
      final manager = _ControlledHashManager();
      final existing = manager.hashAssets();
      manager.catalog.add('first-copy');
      final first = manager.hashAssets(enqueue: true);
      manager.finish(0);
      await existing;
      manager.catalog.add('later-copy');
      var laterFinished = false;
      final later = manager.hashAssets(enqueue: true).then((_) => laterFinished = true);
      manager.finish(1);
      await first;
      expect(laterFinished, isFalse);
      expect(manager.runs, hasLength(3));
      manager.finish(2);
      await later;
      expect(manager.hashed, containsAll(['first-copy', 'later-copy']));
      await manager.cancel();
    });

    test('a failed follow-up reports failure without a retry loop and a later explicit request can recover', () async {
      final errors = <String>[];
      final manager = _ControlledHashManager(onHashingError: errors.add);
      final existing = manager.hashAssets();
      final saved = manager.hashAssets(enqueue: true);
      final rejected = expectLater(saved, throwsStateError);
      manager.finish(0);
      await existing;
      manager.runs.last.completeError(StateError('synthetic hash failure'));
      await rejected;
      await Future<void>.delayed(Duration.zero);
      expect(manager.runs, hasLength(2));
      expect(errors, hasLength(1));

      final retry = manager.hashAssets(enqueue: true);
      expect(manager.runs, hasLength(3));
      manager.finish(2);
      await retry;
      await manager.cancel();
    });

    test(
      'SQLite failure rejects the follow-up before another writer and blocks hashing until validated recovery',
      () async {
        final manager = _ControlledHashManager();
        final existing = manager.hashAssets();
        final saved = manager.hashAssets(enqueue: true);
        final rejected = expectLater(saved, throwsA(isA<SqliteDatabaseUnhealthy>()));
        manager.runs.single.completeError(const SqliteDatabaseUnhealthy('hash-assets', 779));
        await Future.wait([existing, rejected]);
        expect(manager.sqliteRecoveryRequired, isTrue);
        expect(manager.runs, hasLength(1));
        await manager.hashAssets();
        await expectLater(manager.hashAssets(enqueue: true), throwsStateError);
        expect(manager.runs, hasLength(1));

        manager.clearSqliteRecoveryAfterValidatedRecovery();
        final recovered = manager.hashAssets(enqueue: true);
        manager.finish(1);
        await recovered;
        expect(manager.sqliteRecoveryRequired, isFalse);
        await manager.cancel();
      },
    );

    test('an explicit idle hash request observes cancellation instead of continuing backup', () async {
      final manager = _ControlledHashManager();
      final saved = manager.hashAssets(enqueue: true);
      final cancelled = expectLater(saved, throwsA(isA<CanceledError>()));
      await manager.cancel();
      await cancelled;
      expect(manager.runs, hasLength(1));
    });

    test('cancelling the active follow-up also rejects the original editor waiter', () async {
      final manager = _ControlledHashManager();
      final existing = manager.hashAssets();
      final saved = manager.hashAssets(enqueue: true);
      final cancelled = expectLater(saved, throwsA(isA<CanceledError>()));
      manager.finish(0);
      await existing;
      expect(manager.runs, hasLength(2));
      await manager.cancelResumeSyncs();
      await cancelled;
      expect(manager.runs, hasLength(2));
      await manager.cancel();
    });

    for (final resumeOnly in [false, true]) {
      test('${resumeOnly ? 'resume' : 'full'} cancellation rejects queued waits and prevents follow-up work', () async {
        final manager = _ControlledHashManager();
        final existing = manager.hashAssets();
        final saved = manager.hashAssets(enqueue: true);
        final cancelled = expectLater(saved, throwsA(isA<CanceledError>()));
        await (resumeOnly ? manager.cancelResumeSyncs() : manager.cancel());
        await Future.wait([existing, cancelled]);
        expect(manager.runs, hasLength(1));
        expect(manager.cancellations, 1);
        await manager.cancel();
      });
    }

    test('a draining old pass cannot queue work or clear the replacement hash owner after cancellation', () async {
      final manager = _ControlledHashManager(drainOnCancel: true);
      final existing = manager.hashAssets();
      final saved = manager.hashAssets(enqueue: true);
      final cancelled = expectLater(saved, throwsA(isA<CanceledError>()));
      final stopping = manager.cancelResumeSyncs();
      final replacement = manager.hashAssets(enqueue: true);
      manager.finish(0);
      await Future.wait([existing, stopping, cancelled]);
      expect(manager.runs, hasLength(2));
      final joined = manager.hashAssets();
      expect(manager.runs, hasLength(2));
      manager.finish(1);
      await Future.wait([replacement, joined]);
      expect(manager.runs, hasLength(2));
      await manager.cancel();
    });
  });

  test('a receipt validation failure releases remote sync so a later successful pass can resume backup', () async {
    final errors = <String>[];
    final completions = <bool?>[];
    final manager = _QueuedRemoteSyncManager(onRemoteSyncComplete: completions.add, onRemoteSyncError: errors.add);

    final failed = manager.syncRemote();
    manager.runs.single.completeError(StateError('Incomplete deletion acknowledgement'));
    expect(await failed, isFalse);
    expect(manager.sqliteRecoveryRequired, isFalse);
    expect(errors.single, contains('Incomplete deletion acknowledgement'));

    final recovered = manager.syncRemote();
    expect(manager.runs, hasLength(2));
    manager.runs.last.complete(true);
    expect(await recovered, isTrue);
    expect(completions, [true]);
    expect(errors, hasLength(1));
    expect(manager.runs, hasLength(2));
    await manager.cancel();
  });

  test('Build28 concurrent saved-copy refreshes coalesce into one follow-up server pass', () async {
    final completions = <bool?>[];
    final manager = _QueuedRemoteSyncManager(onRemoteSyncComplete: completions.add);
    final first = manager.syncRemote();
    final refreshes = [for (var index = 0; index < 4; index++) manager.syncRemote(enqueue: true)];
    expect(manager.runs, hasLength(1));
    manager.runs.first.complete(true);
    expect(await first, isTrue);
    expect(await Future.wait(refreshes), everyElement(isTrue));
    // Those Futures refer to the pre-existing pass. The queued pass still owns
    // the next server checkpoint, so callers must not declare the copy imported.
    expect(manager.runs, hasLength(2));
    expect(manager.runs.last.isCompleted, isFalse);
    expect(completions, [true]);
    manager.runs.last.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(completions, [true, true]);
    expect(manager.runs, hasLength(2));
    expect(manager.localRequests, 0);
    expect(manager.hashRequests, 0);
    await manager.cancel();
  });

  for (final throws in [false, true]) {
    test('Build28 queued follow-up ${throws ? 'error' : 'false result'} stops without an active retry loop', () async {
      final errors = <String>[];
      final completions = <bool?>[];
      final manager = _QueuedRemoteSyncManager(onRemoteSyncComplete: completions.add, onRemoteSyncError: errors.add);
      final first = manager.syncRemote();
      final request = manager.syncRemote(enqueue: true);
      manager.runs.first.complete(true);
      expect(await first, isTrue);
      expect(await request, isTrue);
      expect(manager.runs, hasLength(2));
      if (throws) {
        manager.runs.last.completeError(StateError('synthetic follow-up failure'));
      } else {
        manager.runs.last.complete(false);
      }
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(manager.runs, hasLength(2));
      expect(completions, throws ? [true] : [true, false]);
      expect(errors, throws ? hasLength(1) : isEmpty);
      expect(manager.localRequests, 0);
      expect(manager.hashRequests, 0);
      await manager.cancel();
    });
  }

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

  test('SQLite recovery failure gates root remote sync until explicit clear', () async {
    final manager = _ControlledBackgroundSyncManager();
    final first = manager.syncRemote();
    manager.remote.completeError(const SqliteDatabaseUnhealthy('updateAssetsV2[user]', 779));

    expect(await first.timeout(const Duration(seconds: 2)), isFalse);
    expect(manager.sqliteRecoveryRequired, isTrue);

    // The next request is rejected in the root isolate and cannot create a
    // fresh worker with a process-local gate that has been reset.
    expect(await manager.syncRemote().timeout(const Duration(seconds: 2)), isFalse);
    await manager.syncWebsocketBatchV2([]);
    await manager.syncWebsocketEditV2(const {});

    manager.clearSqliteRecoveryAfterValidatedRecovery();
    expect(manager.sqliteRecoveryRequired, isFalse);
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
