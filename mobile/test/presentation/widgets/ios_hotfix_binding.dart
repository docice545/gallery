import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reuses the existing fixtures through Flutter's iOS branches. Keep separate
/// suite entrypoints so their Store/Drift databases retain isolate ownership.
/// Native PhotoKit, provisioning and installation still require an iPhone.
class IosHotfixTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  Future<void> runTest(Future<void> Function() testBody, VoidCallback invariantTester, {String description = ''}) {
    return super.runTest(
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await testBody();
        } finally {
          // Restore before Flutter verifies its own debug-variable invariants,
          // just as TargetPlatformVariant does for an individual testWidgets.
          debugDefaultTargetPlatformOverride = null;
        }
      },
      invariantTester,
      description: description,
    );
  }
}
