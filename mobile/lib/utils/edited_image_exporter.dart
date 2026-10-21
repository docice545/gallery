import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/utils/annotation_painter.dart';
import 'package:immich_mobile/utils/color_adjustment.dart';

/// Renders the edit document in source-image coordinates, then applies the crop
/// and orthogonal transforms. The viewport, zoom and editor chrome are excluded.
class EditedImageExporter {
  const EditedImageExporter._();

  static const sourceLoadTimeout = Duration(seconds: 30);

  /// Returns an owned image handle and detaches on success, failure or timeout.
  /// Removing the listener also lets cancellable providers abandon the request.
  static Future<ui.Image> loadSource(ImageProvider provider, {Duration timeout = sourceLoadTimeout}) async {
    final stream = provider.resolve(ImageConfiguration.empty);
    final result = Completer<ui.Image>();
    final listener = ImageStreamListener(
      (info, _) {
        try {
          if (!result.isCompleted) {
            result.complete(info.image.clone());
          }
        } finally {
          info.dispose();
        }
      },
      onError: (Object error, StackTrace? stack) {
        if (!result.isCompleted) {
          result.completeError(error, stack);
        }
      },
    );
    try {
      stream.addListener(listener);
      return await result.future.timeout(timeout);
    } finally {
      stream.removeListener(listener);
    }
  }

  static Future<ui.Image> render({
    required ui.Image source,
    required Rect crop,
    required int rotationDegrees,
    required bool flipHorizontal,
    required bool flipVertical,
    required List<AnnotationElement> annotations,
    Map<String, double> adjustments = const {},
    int selectedFilterIndex = 0,
    double filterIntensity = 1.0,
  }) async {
    final safeCrop = Rect.fromLTRB(
      crop.left.clamp(0.0, 1.0),
      crop.top.clamp(0.0, 1.0),
      crop.right.clamp(0.0, 1.0),
      crop.bottom.clamp(0.0, 1.0),
    );
    if (safeCrop.isEmpty) {
      throw ArgumentError.value(crop, 'crop', 'Crop must have positive width and height');
    }

    final left = (safeCrop.left * source.width).round().clamp(0, source.width - 1);
    final top = (safeCrop.top * source.height).round().clamp(0, source.height - 1);
    final right = (safeCrop.right * source.width).round().clamp(left + 1, source.width);
    final bottom = (safeCrop.bottom * source.height).round().clamp(top + 1, source.height);
    final cropWidth = right - left;
    final cropHeight = bottom - top;
    final normalizedRotation = ((rotationDegrees % 360) + 360) % 360;
    if (normalizedRotation % 90 != 0) {
      throw ArgumentError.value(rotationDegrees, 'rotationDegrees', 'Only quarter-turn rotations are supported');
    }
    final sideways = normalizedRotation == 90 || normalizedRotation == 270;
    final outputWidth = sideways ? cropHeight : cropWidth;
    final outputHeight = sideways ? cropWidth : cropHeight;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, outputWidth.toDouble(), outputHeight.toDouble()));
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, outputWidth.toDouble(), outputHeight.toDouble()));
    canvas.translate(outputWidth / 2, outputHeight / 2);
    canvas.rotate(normalizedRotation * 3.141592653589793 / 180);
    canvas.scale(flipHorizontal ? -1.0 : 1.0, flipVertical ? -1.0 : 1.0);
    canvas.translate(-(left + cropWidth / 2), -(top + cropHeight / 2));

    final paint = Paint()
      ..filterQuality = FilterQuality.high
      ..colorFilter = ColorAdjustment.combinedFilter(adjustments, selectedFilterIndex, filterIntensity);

    canvas.drawImage(source, Offset.zero, paint);
    AnnotationPainter(annotations).paint(canvas, Size(source.width.toDouble(), source.height.toDouble()));
    canvas.restore();
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(outputWidth, outputHeight);
    } finally {
      picture.dispose();
    }
  }

  static Future<Uint8List> encodePng(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('Unable to encode edited image');
    }
    return data.buffer.asUint8List();
  }
}
