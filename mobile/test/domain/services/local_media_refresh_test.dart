import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/local_media_refresh.dart';

void main() {
  testWidgets('bursts coalesce, changes during sync drain once, and idle never polls', (tester) async {
    final runs = <Completer<void>>[];
    final refresh = LocalMediaRefresh(
      sync: () {
        final run = Completer<void>();
        runs.add(run);
        return run.future;
      },
      onError: (error, stack) => fail('$error'),
    );
    addTearDown(refresh.dispose);
    refresh.setActive(true);
    for (var i = 0; i < 50; i++) {
      refresh.notifyChanged();
    }
    await tester.pump(const Duration(milliseconds: 350));
    expect(runs, hasLength(1));
    for (var i = 0; i < 50; i++) {
      refresh.notifyChanged();
    }
    await tester.pump(const Duration(seconds: 2));
    expect(runs, hasLength(1));
    runs[0].complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(runs, hasLength(2));
    runs[1].complete();
    await tester.pump();
    await tester.pump(const Duration(minutes: 10));
    expect(runs, hasLength(2));
  });

  testWidgets('resume catches missed changes without polling in background; errors can recover', (tester) async {
    var calls = 0;
    final errors = <Object>[];
    final refresh = LocalMediaRefresh(
      sync: () async {
        if (++calls == 1) {
          throw StateError('permission temporarily unavailable');
        }
      },
      onError: (error, _) => errors.add(error),
    );
    refresh.setActive(true);
    await tester.pump(const Duration(milliseconds: 350));
    expect(errors, hasLength(1));
    refresh.setActive(false);
    refresh.notifyChanged();
    await tester.pump(const Duration(minutes: 10));
    expect(calls, 1);
    refresh.setActive(true);
    await tester.pump(const Duration(milliseconds: 350));
    expect(calls, 2);
    refresh.notifyChanged();
    refresh.dispose();
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 2);
  });
}
