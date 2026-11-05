import 'test_utils/sqlite_cloud_media_scenario.dart';

// Register synchronously: a standalone APK starts flutter_test's declarer on
// the next event turn. Platform/file awaits belong inside the registered test.
void main() => cloudMediaScenario();
