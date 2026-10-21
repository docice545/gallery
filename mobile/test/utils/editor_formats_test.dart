import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final name in ['sample.png', 'orientation-6.jpg']) {
    test('decodes $name with correct orientation and exports a new raster without changing source bytes', () async {
      final file = File('test/fixtures/editor-formats/$name');
      final original = await file.readAsBytes();
      final source = await EditedImageExporter.loadSource(MemoryImage(Uint8List.fromList(original)));
      ui.Image? output;
      try {
        final oriented = name.endsWith('.jpg');
        expect((source.width, source.height), oriented ? (8, 12) : (12, 8));
        final bytes = (await source.toByteData())!;
        final red = (2 * source.width + 2) * 4;
        final blue = ((oriented ? 9 : 2) * source.width + (oriented ? 2 : 9)) * 4;
        expect(bytes.getUint8(red), greaterThan(245));
        expect(bytes.getUint8(red + 2), lessThan(10));
        expect(bytes.getUint8(blue + 2), greaterThan(245));
        expect(bytes.getUint8(blue), lessThan(10));
        output = await EditedImageExporter.render(
          source: source,
          crop: const ui.Rect.fromLTWH(0, 0, 1, 1),
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          annotations: [],
        );
        final png = await EditedImageExporter.encodePng(output);
        expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        expect(await output.toByteData(), isNotNull);
        expect(await file.readAsBytes(), original);
        // The exported raster already has EXIF orientation baked in, so copying
        // the old orientation tag would rotate it twice. Other EXIF is not copied.
        final codec = await ui.instantiateImageCodec(png);
        final roundTrip = (await codec.getNextFrame()).image;
        try {
          expect((roundTrip.width, roundTrip.height), (source.width, source.height));
        } finally {
          roundTrip.dispose();
          codec.dispose();
        }
      } finally {
        source.dispose();
        output?.dispose();
      }
    });
  }
}
