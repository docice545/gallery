import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon_paths.dart';

void main() {
  test('FOTO share icon uses three-node share geometry', () {
    final svg = fotoIconPaths[FotoIconKind.share];

    expect(svg, isNotNull);
    expect(RegExp(r'<circle ').allMatches(svg!).length, 3);
    expect(RegExp(r'<path ').allMatches(svg).length, 2);

    expect(svg, contains('M8.59 13.51 15.42 17.49'));
    expect(svg, contains('M15.41 6.51 8.59 10.49'));

    expect(svg, isNot(contains('M12 15V3.5')));
  });
}
