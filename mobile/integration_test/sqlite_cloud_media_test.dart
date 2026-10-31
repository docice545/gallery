import 'dart:io';

import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'test_utils/sqlite_cloud_media_scenario.dart';

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final directory = await getApplicationDocumentsDirectory();
  final mode = (await File('${directory.path}/cloud24-mode').readAsString()).trim();
  if (mode != 'first' && mode != 'restart') {
    throw StateError('The synthetic emulator host must select first/restart');
  }
  cloudMediaScenario(restart: mode == 'restart');
}
