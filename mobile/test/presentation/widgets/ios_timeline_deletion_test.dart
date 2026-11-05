import 'package:flutter_test/flutter_test.dart';

import 'ios_hotfix_binding.dart';
import 'timeline/timeline_ghost_deletion_test.dart' as deletion;

void main() {
  IosHotfixTestBinding();
  group('iOS branded Timeline deletion', deletion.main);
}
