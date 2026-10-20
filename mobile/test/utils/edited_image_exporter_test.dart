import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';

import '../fixtures/editor_raster.dart';

void main() {
  late ui.Image source;

  setUp(() async {
    source = await createEditorRaster();
  });

  tearDown(() => source.dispose());

  test('keeps source dimensions and pixels without editor viewport dependence', () async {
    final output = await EditedImageExporter.render(
      source: source,
      crop: const Rect.fromLTRB(0, 0, 1, 1),
      rotationDegrees: 0,
      flipHorizontal: false,
      flipVertical: false,
      annotations: const [],
    );
    addTearDown(output.dispose);

    expect((output.width, output.height), (64, 48));
    expect(await _pixel(output, 8, 8), Colors.red.toARGB32());
    expect(await _pixel(output, 24, 8), Colors.green.toARGB32());
    expect(await _pixel(output, 8, 40), Colors.orange.toARGB32());
    expect(await _pixel(output, 56, 40), Colors.pink.toARGB32());
  });

  test('applies a source-relative crop and preserves pixel dimensions', () async {
    final output = await EditedImageExporter.render(
      source: source,
      crop: const Rect.fromLTRB(.25, 1 / 3, .75, 2 / 3),
      rotationDegrees: 0,
      flipHorizontal: false,
      flipVertical: false,
      annotations: const [],
    );
    addTearDown(output.dispose);

    expect((output.width, output.height), (32, 16));
    expect(await _pixel(output, 8, 8), Colors.black.toARGB32());
    expect(await _pixel(output, 24, 8), Colors.cyan.toARGB32());
  });

  test('rotates and flips pixels in the same output coordinate system', () async {
    final output = await EditedImageExporter.render(
      source: source,
      crop: const Rect.fromLTRB(0, 0, 1, 1),
      rotationDegrees: 90,
      flipHorizontal: true,
      flipVertical: false,
      annotations: const [],
    );
    addTearDown(output.dispose);

    expect((output.width, output.height), (48, 64));
    // Horizontal reflection in source space followed by a clockwise rotation.
    expect(await _pixel(output, 8, 8), Colors.pink.toARGB32());
    expect(await _pixel(output, 40, 8), Colors.yellow.toARGB32());
    expect(await _pixel(output, 8, 56), Colors.orange.toARGB32());
    expect(await _pixel(output, 40, 56), Colors.red.toARGB32());
  });

  test('paints annotations into source pixels before cropping and transformation', () async {
    final annotation = AnnotationElement(
      id: 'line',
      tool: AnnotationTool.pen,
      points: const [Offset(.25, .5), Offset(.75, .5)],
      color: Colors.white,
      width: 120,
      opacity: 1,
    );
    final output = await EditedImageExporter.render(
      source: source,
      crop: const Rect.fromLTRB(0, 0, 1, 1),
      rotationDegrees: 0,
      flipHorizontal: false,
      flipVertical: false,
      annotations: [annotation],
    );
    addTearDown(output.dispose);

    final pixels = await _pixels(output);
    expect(pixels.any((value) => value == Colors.white.toARGB32()), isTrue);
    final bytes = await EditedImageExporter.encodePng(output);
    expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final codec = await ui.instantiateImageCodec(bytes);
    addTearDown(codec.dispose);
    final decoded = (await codec.getNextFrame()).image;
    addTearDown(decoded.dispose);
    expect((decoded.width, decoded.height), (64, 48));
    expect(await _pixels(decoded), pixels);
  });

  for (final cropped in [false, true]) {
    for (final turn in [0, 1, 2, 3]) {
      for (final horizontal in [false, true]) {
        for (final vertical in [false, true]) {
          test(
            'source pixels and markup: crop=$cropped turn=$turn horizontal=$horizontal vertical=$vertical',
            () async {
              const marker = Color(0xFF123456);
              final annotation = AnnotationElement(
                id: 'marker',
                tool: AnnotationTool.pen,
                points: const [Offset(.625, .5)],
                color: marker,
                width: 60,
                opacity: 1,
              );
              final output = await EditedImageExporter.render(
                source: source,
                // Off-center and non-square: origin mistakes cannot pass by symmetry.
                crop: cropped ? const Rect.fromLTRB(.25, 0, 1, 2 / 3) : const Rect.fromLTRB(0, 0, 1, 1),
                rotationDegrees: turn * 90,
                flipHorizontal: horizontal,
                flipVertical: vertical,
                annotations: [annotation],
              );
              addTearDown(output.dispose);

              var expected = [
                for (var y = 0; y < (cropped ? 2 : 3); y++)
                  [for (var x = cropped ? 1 : 0; x < 4; x++) y == 1 && x == 2 ? marker : editorRasterColors[y][x]],
              ];
              if (horizontal) {
                expected = [for (final row in expected) row.reversed.toList()];
              }
              if (vertical) {
                expected = expected.reversed.toList();
              }
              expected = rotateEditorTiles(expected, turn);
              expect((output.width, output.height), (expected.first.length * 16, expected.length * 16));
              expect(await sampleEditorTiles(output, columns: expected.first.length, rows: expected.length), [
                for (final row in expected) [for (final color in row) color.toARGB32()],
              ]);
              // Export must not paint over the source texture shared with preview.
              expect(await _pixel(source, 40, 24), Colors.cyan.toARGB32());
            },
          );
        }
      }
    }
  }

  for (final angle in [-450, -90, 630]) {
    test('normalizes rotation $angle like the preview quarter-turn', () async {
      final output = await EditedImageExporter.render(
        source: source,
        crop: const Rect.fromLTRB(0, 0, 1, 1),
        rotationDegrees: angle,
        flipHorizontal: false,
        flipVertical: false,
        annotations: const [],
      );
      addTearDown(output.dispose);
      final expected = rotateEditorTiles(editorRasterColors, 3);
      expect((output.width, output.height), (48, 64));
      expect(await sampleEditorTiles(output, columns: 3, rows: 4), [
        for (final row in expected) [for (final color in row) color.toARGB32()],
      ]);
    });
  }
}

Future<int> _pixel(ui.Image image, int x, int y) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final offset = (y * image.width + x) * 4;
  final data = bytes!.buffer.asUint8List();
  return (data[offset + 3] << 24) | (data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2];
}

Future<List<int>> _pixels(ui.Image image) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final data = bytes!.buffer.asUint8List();
  return [
    for (var offset = 0; offset < data.length; offset += 4)
      (data[offset + 3] << 24) | (data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2],
  ];
}
