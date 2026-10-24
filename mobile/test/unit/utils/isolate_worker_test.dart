import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/wm_executor.dart';
import 'package:worker_manager/worker_manager.dart';

Future<String> Function(Completer<void>) _drainingWork(SendPort output) => (onCancel) async {
  final continuation = ReceivePort();
  output.send(continuation.sendPort);
  await onCancel.future;
  output.send('cancelled');
  await continuation.first;
  continuation.close();
  return 'native-and-db-drained';
};

Future<void> Function(Completer<void>) _waitingWork(SendPort output) => (onCancel) async {
  output.send('started');
  await onCancel.future;
};

void main() {
  tearDown(workerManagerPatch.dispose);

  test('dispose() drains a cancelled task and delivers its result', () async {
    await workerManagerPatch.init(isolatesCount: 1, dynamicSpawning: false);

    final task = workerManagerPatch.executeGentle((onCancel) async {
      await onCancel.future;
      return 'drained';
    });

    await workerManagerPatch.dispose();

    expect(
      await task.timeout(const Duration(seconds: 5)),
      'drained',
      reason: 'the worker must finish and return its result, not be killed mid-task',
    );
  });

  test('owned cancellation waits for the worker continuation to drain', () async {
    await workerManagerPatch.init(isolatesCount: 1, dynamicSpawning: false);
    final events = ReceivePort();
    final output = events.sendPort;
    final ready = Completer<SendPort>();
    final cancelled = Completer<void>();
    final subscription = events.listen((event) {
      if (event is SendPort) {
        ready.complete(event);
      }
      if (event == 'cancelled') {
        cancelled.complete();
      }
    });
    addTearDown(() async {
      await subscription.cancel();
      events.close();
    });

    final task = workerManagerPatch.executeGentle(_drainingWork(output), awaitCancellationDrain: true);
    final resume = await ready.future.timeout(const Duration(seconds: 5));
    var finished = false;
    unawaited(task.then((_) => finished = true));
    task.cancel();
    await cancelled.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse, reason: 'cancellation must not detach an active native/DB continuation');
    resume.send(null);
    expect(await task.timeout(const Duration(seconds: 5)), 'native-and-db-drained');
  });

  test('owned cancellation removes queued work without waiting for a worker', () async {
    await workerManagerPatch.init(isolatesCount: 1, dynamicSpawning: false);
    final events = ReceivePort();
    final output = events.sendPort;
    final first = workerManagerPatch.executeGentle(_waitingWork(output), awaitCancellationDrain: true);
    await events.first.timeout(const Duration(seconds: 5));
    events.close();
    final queued = workerManagerPatch.executeGentle((_) => 'must-not-run', awaitCancellationDrain: true);
    final cancelled = expectLater(queued.future, throwsA(isA<CanceledError>()));
    queued.cancel();
    await cancelled;
    first.cancel();
    await first.timeout(const Duration(seconds: 5));
  });

  test('pending dedicated trash cannot starve hashing in a one-worker pool', () async {
    await workerManagerPatch.init(isolatesCount: 1, dynamicSpawning: false);
    final events = ReceivePort();
    final ready = Completer<SendPort>();
    final cancelled = Completer<void>();
    final subscription = events.listen((event) {
      if (event is SendPort) {
        ready.complete(event);
      }
      if (event == 'cancelled') {
        cancelled.complete();
      }
    });
    addTearDown(() async {
      await subscription.cancel();
      events.close();
    });

    final trash = workerManagerPatch.executeGentle(_drainingWork(events.sendPort), dedicated: true);
    final resume = await ready.future.timeout(const Duration(seconds: 5));
    var trashFinished = false;
    unawaited(trash.then((_) => trashFinished = true));
    final hashing = workerManagerPatch.executeGentle((_) => 'new-photo-hashed');
    expect(await hashing.timeout(const Duration(seconds: 5)), 'new-photo-hashed');
    expect(trashFinished, isFalse, reason: 'the Android request is deliberately still pending');

    trash.cancel();
    await cancelled.future.timeout(const Duration(seconds: 5));
    expect(trashFinished, isFalse, reason: 'dedicated cancellation must wait for the actual DB continuation');
    resume.send(null);
    expect(await trash.timeout(const Duration(seconds: 5)), 'native-and-db-drained');
  });

  test('dedicated cancellation before initialization skips computation and drains the isolate', () async {
    final events = ReceivePort();
    final observed = <Object?>[];
    final subscription = events.listen(observed.add);
    addTearDown(() async {
      await subscription.cancel();
      events.close();
    });
    final task = workerManagerPatch.executeGentle(_waitingWork(events.sendPort), dedicated: true);
    final stopped = expectLater(task.future, throwsA(isA<CanceledError>()));
    task.cancel();
    await stopped.timeout(const Duration(seconds: 5));
    expect(observed, isEmpty, reason: 'cancelled initialization must not enter the media computation');
    await workerManagerPatch.dispose();
  });

  test('global dispose includes dedicated maintenance and waits for its continuation', () async {
    final events = ReceivePort();
    final ready = Completer<SendPort>();
    final cancelled = Completer<void>();
    final subscription = events.listen((event) {
      if (event is SendPort) {
        ready.complete(event);
      }
      if (event == 'cancelled') {
        cancelled.complete();
      }
    });
    addTearDown(() async {
      await subscription.cancel();
      events.close();
    });
    final task = workerManagerPatch.executeGentle(_drainingWork(events.sendPort), dedicated: true);
    final resume = await ready.future.timeout(const Duration(seconds: 5));
    var disposed = false;
    final stopping = workerManagerPatch.dispose().then((_) => disposed = true);
    await cancelled.future.timeout(const Duration(seconds: 5));
    expect(disposed, isFalse);
    resume.send(null);
    await stopping.timeout(const Duration(seconds: 5));
    expect(await task, 'native-and-db-drained');
    expect(disposed, isTrue);
  });
}
