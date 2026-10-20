import 'dart:math' as math;
import 'dart:ui' show Color, Offset;

/// Tools supported by the photo markup editor.
enum AnnotationTool { pen, brush, highlighter, eraser, text, move, arrow, rectangle, ellipse }

/// A normalized point (0..1 in the image's coordinate space) used by markup.
/// Keeping coordinates independent of the preview size makes the result stable
/// while the image is rotated, zoomed, or displayed on another device.
class AnnotationElement {
  final String id;
  final AnnotationTool tool;
  final List<Offset> points;
  final Color color;

  /// Stroke width as a fraction of the image's shortest side.
  final double width;
  final double opacity;
  final String? text;
  final double fontSize;

  AnnotationElement({
    required this.id,
    required this.tool,
    required List<Offset> points,
    required this.color,
    required this.width,
    required this.opacity,
    this.text,
    this.fontSize = 0.06,
  }) : points = List.unmodifiable(points),
       assert(points.isNotEmpty),
       assert(width > 0),
       assert(opacity >= 0 && opacity <= 1);

  bool get isText => tool == AnnotationTool.text;
  bool get isShape =>
      tool == AnnotationTool.arrow || tool == AnnotationTool.rectangle || tool == AnnotationTool.ellipse;

  AnnotationElement translated(Offset delta) {
    // Clamp the shared displacement, preserving distances between all points.
    final left = points.map((point) => point.dx).reduce(math.min);
    final right = points.map((point) => point.dx).reduce(math.max);
    final top = points.map((point) => point.dy).reduce(math.min);
    final bottom = points.map((point) => point.dy).reduce(math.max);
    final displacement = Offset(delta.dx.clamp(-left, 1 - right), delta.dy.clamp(-top, 1 - bottom));
    return copyWith(points: points.map((point) => point + displacement).toList(growable: false));
  }

  AnnotationElement copyWith({
    List<Offset>? points,
    String? text,
    Color? color,
    double? width,
    double? opacity,
    double? fontSize,
  }) => AnnotationElement(
    id: id,
    tool: tool,
    points: points ?? this.points,
    color: color ?? this.color,
    width: width ?? this.width,
    opacity: opacity ?? this.opacity,
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
  );

  @override
  bool operator ==(Object other) =>
      other is AnnotationElement &&
      other.id == id &&
      other.tool == tool &&
      _samePoints(other.points, points) &&
      other.color == color &&
      other.width == width &&
      other.opacity == opacity &&
      other.text == text &&
      other.fontSize == fontSize;

  @override
  int get hashCode => Object.hash(id, tool, Object.hashAll(points), color, width, opacity, text, fontSize);

  static bool _samePoints(List<Offset> a, List<Offset> b) =>
      a.length == b.length && a.indexed.every((entry) => entry.$2 == b[entry.$1]);
}
