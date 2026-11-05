import 'package:flutter_test/flutter_test.dart';

import 'asset_viewer/unified_action_bars_test.dart' as bars;
import 'ios_hotfix_binding.dart';

void main() {
  IosHotfixTestBinding();
  group('iOS unified action bars', () => bars.runUnifiedActionBarsTests(ios: true));
}
