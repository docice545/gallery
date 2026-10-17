import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_stack.widget.dart';

void main() {
  test('formats the selected stack position using one-based indexing', () {
    expect(stackPositionLabel(2, 5), '3/5');
  });

  test('clamps a stale viewer index to the last stack member', () {
    expect(stackPositionLabel(99, 5), '5/5');
  });

  test('does not render a position for an empty stack', () {
    expect(stackPositionLabel(0, 0), isEmpty);
  });
}
