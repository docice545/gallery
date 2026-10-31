import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/infrastructure/repositories/cloud_media.repository.dart';
import 'package:immich_mobile/main.dart' as application;
import 'package:immich_mobile/utils/isolate.dart';

/// Run real production bootstrap, then let the test binding receive every
/// application error. initApp's logging handlers must not swallow test failures
/// or replace FlutterTestWidgetsBinding's pending-exception bookkeeping.
Future<void> openFotoForTest() async {
  final flutterError = FlutterError.onError;
  final platformError = WidgetsBinding.instance.platformDispatcher.onError;
  try {
    await application.openFoto();
  } finally {
    FlutterError.onError = flutterError;
    WidgetsBinding.instance.platformDispatcher.onError = platformError;
  }
}

/// Real production worker bootstrap/close must neither register an unsupported
/// inbound handler nor unregister the foreground engine's admitted reader.
Future<void> verifyWorkerKeepsNativeReader() async {
  final worker = runInIsolateGentle<Map<String, Object?>>(
    debugLabel: 'recovery-worker-admission',
    computation: (ref) async => {
      'root': ServicesBinding.rootIsolateToken != null,
      'tables':
          (await ref
                  .read(Store.db)
                  .customSelect("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table'")
                  .getSingle())
              .data['n'],
    },
  );
  final result = await worker.future.timeout(const Duration(seconds: 60));
  expect(result?['root'], false);
  expect(result?['tables'], greaterThan(50));
  expect((await const CloudMediaRepository().status())['sqliteReaderReady'], true);
}
