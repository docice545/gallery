import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/utils/annotation_painter.dart';
import 'package:immich_mobile/utils/color_adjustment.dart';
import 'package:immich_mobile/utils/editor_geometry.dart';

class ImageExportCancelledException implements Exception {
  const ImageExportCancelledException();
}

class ImageExportLimitException implements Exception {
  const ImageExportLimitException();
}

/// Renders the edit document in source-image coordinates, then applies the crop
/// and geometry. The viewport, zoom and editor chrome are excluded.
class EditedImageExporter {
  const EditedImageExporter._();

  static const maxPixels = 32 * 1024 * 1024;
  static void validateDimensions(int width, int height) {
    if (width <= 0 || height <= 0 || width * height > maxPixels) {
      throw const ImageExportLimitException();
    }
  }

  static const sourceLoadTimeout = Duration(seconds: 30);

  /// Returns an owned image handle and detaches on success, failure or timeout.
  /// Removing the listener also lets cancellable providers abandon the request.
  static Future<ui.Image> loadSource(
    ImageProvider provider, {
    Duration timeout = sourceLoadTimeout,
    Future<void>? cancel,
  }) async {
    final stream = provider.resolve(ImageConfiguration.empty);
    final result = Completer<ui.Image>();
    final listener = ImageStreamListener(
      (info, _) {
        try {
          if (!result.isCompleted) {
            if (info.image.width * info.image.height > maxPixels) {
              result.completeError(const ImageExportLimitException());
            } else {
              result.complete(info.image.clone());
            }
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
    final deadline = Timer(timeout, () {
      if (!result.isCompleted) {
        result.completeError(TimeoutException('Original image load timed out', timeout));
      }
    });
    if (cancel != null) {
      unawaited(
        cancel.then((_) {
          if (!result.isCompleted) {
            result.completeError(const ImageExportCancelledException());
          }
        }),
      );
    }
    try {
      stream.addListener(listener);
      return await result.future;
    } finally {
      deadline.cancel();
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
    double straightenDegrees = 0,
    Map<String, double> adjustments = const {},
    int selectedFilterIndex = 0,
    double filterIntensity = 1.0,
  }) async {
    validateDimensions(source.width, source.height);
    if (![crop.left, crop.top, crop.right, crop.bottom].every((v) => v.isFinite)) {
      throw ArgumentError.value(crop, 'crop');
    }
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
    final geometry = EditorGeometry(
      sourceRect: Rect.fromLTRB(left.toDouble(), top.toDouble(), right.toDouble(), bottom.toDouble()),
      rotationDegrees: rotationDegrees,
      flipHorizontal: flipHorizontal,
      flipVertical: flipVertical,
      straightenDegrees: straightenDegrees,
    );
    final outputWidth = geometry.outputSize.width.toInt();
    final outputHeight = geometry.outputSize.height.toInt();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, outputWidth.toDouble(), outputHeight.toDouble()));
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, outputWidth.toDouble(), outputHeight.toDouble()));
    canvas.transform(geometry.sourceToOutputTransform.storage);

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
