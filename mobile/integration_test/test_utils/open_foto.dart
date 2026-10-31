import 'package:flutter/widgets.dart';
import 'package:immich_mobile/main.dart' as application;

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
