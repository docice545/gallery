import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/background_work_lifecycle.dart';

void main() {
  late BackgroundWorkLifecycle lifecycle;
  late Completer<void> cancellation;
  late List<String> events;
  late bool dbClosed;
  late int closeCount;
  late Future<void> Function() nativeCancel;
  late Future<void> Function() callbackDrain;

  setUp(() {
    events = [];
    dbClosed = false;
    closeCount = 0;
    cancellation = Completer<void>();
    nativeCancel = () async => events.add('native-drained');
    callbackDrain = () async => events.add('callbacks-drained');
    lifecycle = BackgroundWorkLifecycle(
      cancellation: cancellation,
      cancelNativeWork: () => nativeCancel(),
      drainCallbacks: () => callbackDrain(),
      closeResources: () async {
        events.add('close-db');
        dbClosed = true;
        closeCount++;
      },
    );
  });

  void accessDb(String event) {
    expect(dbClosed, isFalse, reason: 'DB access after teardown: $event');
    events.add(event);
  }

  test('successful work drains before closing and reports success once', () async {
    final success = await lifecycle.run(() async => accessDb('sync'));
    expect(success, isTrue);
    expect(events, ['sync', 'native-drained', 'callbacks-drained', 'close-db']);
    expect(await lifecycle.finish(), isTrue);
    expect(closeCount, 1);
    expect(lifecycle.acceptsWork, isFalse);
  });

  test('failed work reports failure after resource cleanup', () async {
    expect(await lifecycle.run(() async => throw StateError('sync failed')), isFalse);
    expect(closeCount, 1);
    expect(await lifecycle.finish(), isFalse);
  });

  test('explicit cancellation prevents new work and waits an active upload', () async {
    final upload = Completer<void>();
    final running = lifecycle.run(() async {
      accessDb('upload-start');
      await upload.future;
      accessDb('upload-drained');
    });
    await Future<void>.delayed(Duration.zero);
    final cancelling = lifecycle.cancel();
    expect(cancellation.isCompleted, isTrue);
    expect(lifecycle.acceptsWork, isFalse);
    await expectLater(lifecycle.track(() async => accessDb('must-not-run')), throwsStateError);
    expect(dbClosed, isFalse);
    upload.complete();
    expect(await cancelling, isFalse);
    expect(await running, isFalse);
    expect(events.last, 'close-db');
    expect(closeCount, 1);
  });

  test('cancellation while hashing awaits native hash and Dart DB continuation', () async {
    final nativeHash = Completer<void>();
    nativeCancel = () async {
      events.add('hash-cancel-requested');
      await nativeHash.future;
      events.add('hash-native-drained');
    };
    final running = lifecycle.run(() async {
      await nativeHash.future;
      accessDb('hash-Dart-drained');
    });
    final cancelling = lifecycle.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(dbClosed, isFalse);
    nativeHash.complete();
    expect(await cancelling, isFalse);
    expect(await running, isFalse);
    expect(events.indexOf('close-db'), greaterThan(events.indexOf('hash-Dart-drained')));
    expect(events.indexOf('close-db'), greaterThan(events.indexOf('hash-native-drained')));
  });

  testWidgets('timeout requests cancellation and does not detach hashing', (tester) async {
    final hash = Completer<void>();
    final running = lifecycle.run(() async {
      await hash.future;
      accessDb('hash-stopped');
    }, budget: const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(lifecycle.wasCancelled, isTrue);
    expect(dbClosed, isFalse);
    hash.complete();
    await tester.pump();
    expect(await running, isFalse);
    expect(closeCount, 1);
  });

  test('expiration during initialization waits bootstrap owners', () async {
    final init = Completer<void>();
    final initialized = lifecycle.track(() async {
      await init.future;
      accessDb('init-drained');
    });
    final cancelled = lifecycle.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(dbClosed, isFalse);
    init.complete();
    await initialized;
    expect(await cancelled, isFalse);
    expect(events.indexOf('close-db'), greaterThan(events.indexOf('init-drained')));
    expect(await lifecycle.run(() async => accessDb('upload-must-not-start')), isFalse);
  });

  test('one failed concurrent phase waits successful and cancelled peers', () async {
    final sync = Completer<void>();
    final running = lifecycle.run(() async {
      await Future.wait<void>([
        Future<void>.error(StateError('hash failed')),
        sync.future.then((_) => accessDb('last-sync-drained')),
      ]);
    });
    await Future<void>.delayed(Duration.zero);
    expect(dbClosed, isFalse);
    sync.complete();
    expect(await running, isFalse);
    expect(events.indexOf('last-sync-drained'), lessThan(events.indexOf('close-db')));
  });

  test('callback drain waits paired-upload DB continuation before engine close', () async {
    final callback = Completer<void>();
    callbackDrain = () async {
      await callback.future;
      accessDb('paired-resource-callback-drained');
    };
    final running = lifecycle.run(() async => accessDb('upload-enqueued'));
    await Future<void>.delayed(Duration.zero);
    expect(dbClosed, isFalse);
    callback.complete();
    expect(await running, isTrue);
    expect(events.indexOf('paired-resource-callback-drained'), lessThan(events.indexOf('close-db')));
  });

  test('duplicate cancellation and completion calls close resources exactly once', () async {
    final active = Completer<void>();
    final running = lifecycle.run(() => active.future);
    final firstCancel = lifecycle.cancel();
    final secondCancel = lifecycle.cancel();
    final finish = lifecycle.finish();
    active.complete();
    expect(await Future.wait([running, firstCancel, secondCancel, finish]), [false, false, false, false]);
    expect(closeCount, 1);
    expect(events.where((event) => event == 'native-drained').length, 1);
  });

  test('native cancellation failure reports false but drains Dart before close', () async {
    nativeCancel = () async => throw StateError('native cancellation failed');
    expect(await lifecycle.run(() async => accessDb('sync')), isFalse);
    expect(closeCount, 1);
  });

  test('upload callback failure still closes resources and reports false', () async {
    callbackDrain = () async => throw StateError('paired upload failed');
    expect(await lifecycle.run(() async {}), isFalse);
    expect(closeCount, 1);
  });

  test('resource close failure cannot be reported as success', () async {
    final failedClose = BackgroundWorkLifecycle(
      cancellation: cancellation,
      cancelNativeWork: () async {},
      drainCallbacks: () async {},
      closeResources: () async => throw StateError('db close failed'),
    );
    expect(await failedClose.run(() async {}), isFalse);
    expect(await failedClose.finish(), isFalse);
  });

  test('tracked detached legacy phase is drained before DB closes', () async {
    final legacyHash = Completer<void>();
    final running = lifecycle.run(() async {
      unawaited(
        lifecycle.track(() async {
          await legacyHash.future;
          accessDb('legacy-hash-drained');
        }),
      );
      accessDb('backup-finished');
    });
    await Future<void>.delayed(Duration.zero);
    expect(dbClosed, isFalse);
    legacyHash.complete();
    expect(await running, isTrue);
    expect(events.indexOf('legacy-hash-drained'), lessThan(events.indexOf('close-db')));
  });
}
