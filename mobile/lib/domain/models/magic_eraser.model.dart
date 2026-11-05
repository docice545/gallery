import 'dart:math' as math;
import 'dart:ui';

/// A brush stroke in the EXIF-oriented, unedited original image coordinates.
class MagicEraserStroke {
  static const maxPoints = 512;

  final List<Offset> points;
  final double radius;
  final bool erase;

  MagicEraserStroke({required List<Offset> points, required this.radius, this.erase = false})
    : points = List.unmodifiable(points) {
    if (!radius.isFinite || radius < 0.001 || radius > 0.25) {
      throw ArgumentError.value(radius, 'radius');
    }
    if (points.isEmpty || points.length > maxPoints) {
      throw ArgumentError.value(points.length, 'points.length');
    }
    for (final point in points) {
      if (!point.dx.isFinite || !point.dy.isFinite || point.dx < 0 || point.dx > 1 || point.dy < 0 || point.dy > 1) {
        throw ArgumentError.value(point, 'point');
      }
    }
  }

  Map<String, Object> toJson() => {
    'points': [
      for (final point in points) {'x': point.dx, 'y': point.dy},
    ],
    'radius': radius,
    'erase': erase,
  };

  /// Closed contours fill their interior in both preview and Big-LaMa's mask.
  /// Geometry is measured against the upright image's short side, so portrait
  /// and landscape images use the same closure threshold after zoom/pan.
  bool isClosedContour(Size imageSize) {
    if (points.length < 4 || imageSize.isEmpty) {
      return false;
    }
    final short = imageSize.shortestSide;
    final scaled = [
      for (final point in points) Offset(point.dx * imageSize.width / short, point.dy * imageSize.height / short),
    ];
    if ((scaled.first - scaled.last).distance > math.max(radius * 1.5, 0.015)) {
      return false;
    }
    var twiceArea = 0.0;
    for (var i = 0; i < scaled.length; i++) {
      final next = scaled[(i + 1) % scaled.length];
      twiceArea += scaled[i].dx * next.dy - next.dx * scaled[i].dy;
    }
    return twiceArea.abs() > math.max(radius * radius * 8, 0.0008);
  }
}

/// Immutable stroke history. Erasure belongs to the mask, never the source image.
class MagicEraserMask {
  static const maxStrokes = 64;
  static const maxTotalPoints = 8192;

  final List<MagicEraserStroke> strokes;
  final List<MagicEraserStroke> redoStrokes;

  MagicEraserMask({Iterable<MagicEraserStroke> strokes = const [], Iterable<MagicEraserStroke> redoStrokes = const []})
    : strokes = List.unmodifiable(strokes),
      redoStrokes = List.unmodifiable(redoStrokes) {
    if (this.strokes.length > maxStrokes || pointCount > maxTotalPoints) {
      throw ArgumentError('Mask is too complex');
    }
  }

  int get pointCount => strokes.fold(0, (count, stroke) => count + stroke.points.length);
  bool get hasSelection => strokes.any((stroke) => !stroke.erase);
  bool get canUndo => strokes.isNotEmpty;
  bool get canRedo => redoStrokes.isNotEmpty;

  MagicEraserMask add(MagicEraserStroke stroke) => MagicEraserMask(strokes: [...strokes, stroke]);

  MagicEraserMask undo() => !canUndo
      ? this
      : MagicEraserMask(strokes: strokes.take(strokes.length - 1), redoStrokes: [...redoStrokes, strokes.last]);

  MagicEraserMask redo() => !canRedo
      ? this
      : MagicEraserMask(strokes: [...strokes, redoStrokes.last], redoStrokes: redoStrokes.take(redoStrokes.length - 1));

  MagicEraserMask reset() => MagicEraserMask();
}

enum MagicEraserStatus { queued, processing, ready, failed, saved, cancelled }

class MagicEraserJob {
  final String id;
  final MagicEraserStatus status;
  final String? assetId;
  final String? errorCode;

  const MagicEraserJob({required this.id, required this.status, this.assetId, this.errorCode});

  factory MagicEraserJob.fromJson(Map<String, dynamic> json) => MagicEraserJob(
    id: json['id'] as String,
    status: MagicEraserStatus.values.byName(json['status'] as String),
    assetId: json['assetId'] as String?,
    errorCode: json['errorCode'] as String?,
  );
}
