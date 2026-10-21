import 'dart:math' as math;
import 'dart:ui' show Color, Offset, Size;

/// Tools supported by the photo markup editor.
enum AnnotationTool { pen, brush, highlighter, eraser, text, sticker, move, arrow, rectangle, ellipse }

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
  final String? fontFamily;
  final Color outlineColor;
  final double outlineWidth;
  final Color backgroundColor;
  final double rotation;
  final double scale;

  AnnotationElement({
    required this.id,
    required this.tool,
    required List<Offset> points,
    required this.color,
    required this.width,
    required this.opacity,
    this.text,
    this.fontSize = 0.06,
    this.fontFamily,
    this.outlineColor = const Color(0xff000000),
    this.outlineWidth = 0,
    this.backgroundColor = const Color(0x00000000),
    this.rotation = 0,
    this.scale = 1,
  }) : points = List.unmodifiable(points),
       assert(points.isNotEmpty),
       assert(width > 0),
       assert(scale > 0),
       assert(fontSize > 0),
       assert(opacity >= 0 && opacity <= 1);

  bool get isSticker => tool == AnnotationTool.sticker;
  bool get isCaption => isText || isSticker;
  bool get isDrawing => !isCaption;

  /// Transform in source-pixel space, so non-square images do not skew rotation.
  Offset transformPoint(Offset point, Size size, {bool inverse = false}) {
    final anchor = Offset(points.first.dx * size.width, points.first.dy * size.height);
    final delta = point - anchor;
    final angle = inverse ? -rotation : rotation;
    final factor = inverse ? 1 / scale : scale;
    return anchor +
        Offset(
              delta.dx * math.cos(angle) - delta.dy * math.sin(angle),
              delta.dx * math.sin(angle) + delta.dy * math.cos(angle),
            ) *
            factor;
  }

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
    String? fontFamily,
    Color? outlineColor,
    double? outlineWidth,
    Color? backgroundColor,
    double? rotation,
    double? scale,
  }) => AnnotationElement(
    id: id,
    tool: tool,
    points: points ?? this.points,
    color: color ?? this.color,
    width: width ?? this.width,
    opacity: opacity ?? this.opacity,
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
    fontFamily: fontFamily ?? this.fontFamily,
    outlineColor: outlineColor ?? this.outlineColor,
    outlineWidth: outlineWidth ?? this.outlineWidth,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    rotation: rotation ?? this.rotation,
    scale: scale ?? this.scale,
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
      other.fontSize == fontSize &&
      other.fontFamily == fontFamily &&
      other.outlineColor == outlineColor &&
      other.outlineWidth == outlineWidth &&
      other.backgroundColor == backgroundColor &&
      other.rotation == rotation &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(
    id,
    tool,
    Object.hashAll(points),
    color,
    width,
    opacity,
    text,
    fontSize,
    fontFamily,
    outlineColor,
    outlineWidth,
    backgroundColor,
    rotation,
    scale,
  );

  static bool _samePoints(List<Offset> a, List<Offset> b) =>
      a.length == b.length && a.indexed.every((entry) => entry.$2 == b[entry.$1]);
}
