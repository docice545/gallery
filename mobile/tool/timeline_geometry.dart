// Deterministic measurements from the actual production layout, not a second
// implementation or a claim of Google Photos visual parity.
import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/presentation/widgets/timeline/fixed/row_layout.dart';

void main(List<String> arguments) {
  final patterns = <String, List<double>>{
    'squares': List.filled(24, 1),
    'screenshots': List.filled(24, .45),
    'mixed': [
      for (var i = 0; i < 4; i++) ...[.45, .75, 1.5, 1, .45, 2],
    ],
    'singlePortraitDay': [.45],
  };
  final measurements = <Map<String, Object?>>[];
  for (final width in [320.0, 360.0, 390.0, 844.0]) {
    for (final density in [2, 3, 4, 5]) {
      for (final pattern in patterns.entries) {
        final layout = FixedRowLayout.justified(
          width: width,
          aspectRatios: pattern.value,
          columnCount: density,
          spacing: 3,
        );
        measurements.add({
          'viewportDp': width,
          'density': density,
          'pattern': pattern.key,
          'sourceRatios': pattern.value,
          'rows': [
            for (var row = 0; row < layout.rowCount; row++)
              {
                'firstAsset': layout.firstAssetIndexForRow(row),
                'offsetDp': layout.offsetForRow(row),
                'heightDp': layout.heightForRow(row),
                'widthsDp': layout.widthsForRow(row),
                'justified': layout.isJustifiedRow(row),
              },
          ],
        });
      }
    }
  }
  final report =
      '${const JsonEncoder.withIndent('  ').convert({'schema': 1, 'implementation': 'FixedRowLayout.justified', 'gapDp': 3, 'measurementKind': 'production algorithm; synthetic input; not a device screenshot', 'googlePhotosParity': 'NOT_MEASURED', 'measurements': measurements})}\n';
  if (arguments.length == 1) {
    File(arguments.single).writeAsStringSync(report);
  } else {
    stdout.write(report);
  }
}
