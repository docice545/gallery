import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Asymmetric tiles make crop origin, reflection axes and rotation visible.
const editorRasterColors = [
  [Colors.red, Colors.green, Colors.blue, Colors.yellow],
  [Colors.white, Colors.black, Colors.cyan, Color(0xFFFF00FF)],
  [Colors.orange, Colors.purple, Colors.brown, Colors.pink],
];

Future<ui.Image> createEditorRaster() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var y = 0; y < editorRasterColors.length; y++) {
    for (var x = 0; x < editorRasterColors[y].length; x++) {
      canvas.drawRect(Rect.fromLTWH(x * 16, y * 16, 16, 16), Paint()..color = editorRasterColors[y][x]);
    }
  }
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(64, 48);
  } finally {
    picture.dispose();
  }
}

/// A discrete tile permutation, independent of the canvas/export transforms.
List<List<Color>> rotateEditorTiles(List<List<Color>> tiles, int quarterTurns) {
  var result = tiles;
  for (var turn = 0; turn < quarterTurns % 4; turn++) {
    result = [
      for (var x = 0; x < result.first.length; x++) [for (final row in result.reversed) row[x]],
    ];
  }
  return result;
}

Future<List<List<int>>> sampleEditorTiles(ui.Image image, {required int columns, required int rows}) async {
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  return [
    for (var row = 0; row < rows; row++)
      [
        for (var column = 0; column < columns; column++)
          _argb(
            bytes,
            ((row + .5) * image.height / rows).floor() * image.width + ((column + .5) * image.width / columns).floor(),
          ),
      ],
  ];
}

int _argb(List<int> bytes, int pixel) {
  final offset = pixel * 4;
  return (bytes[offset + 3] << 24) | (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];
}
