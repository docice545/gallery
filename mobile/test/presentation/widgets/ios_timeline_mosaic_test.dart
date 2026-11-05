import 'package:flutter_test/flutter_test.dart';

import 'ios_hotfix_binding.dart';
import 'timeline/justified_timeline_widget_test.dart' as mosaic;

void main() {
  IosHotfixTestBinding();
  group('iOS Adaptive Mosaic', mosaic.main);
}
