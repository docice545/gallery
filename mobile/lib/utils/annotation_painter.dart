import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';

/// Annotation stroke widths are fractions of the 360 logical-pixel design side.
const annotationWidthReferenceSide = 360.0;

TextPainter layoutAnnotationText(AnnotationElement element, Size size, {bool outline = false}) => TextPainter(
  text: TextSpan(
    text: element.text,
    style: TextStyle(
      color: outline ? null : element.color.withValues(alpha: element.opacity),
      foreground: outline
          ? (Paint()
              ..color = element.outlineColor.withValues(alpha: element.opacity)
              ..style = PaintingStyle.stroke
              ..strokeWidth = element.outlineWidth * size.shortestSide)
          : null,
      fontFamily: element.fontFamily,
      fontSize: element.fontSize * size.shortestSide,
      fontWeight: FontWeight.w600,
    ),
  ),
  textDirection: ui.TextDirection.ltr,
)..layout(maxWidth: size.width * .8 * element.fontSize / .06);

Rect annotationLocalBounds(AnnotationElement element, Size size) {
  final first = Offset(element.points.first.dx * size.width, element.points.first.dy * size.height);
  if (element.isText) {
    final painter = layoutAnnotationText(element, size);
    final bounds = first & painter.size;
    painter.dispose();
    return bounds;
  }
  if (element.isSticker) {
    return first & Size.square(element.fontSize * size.shortestSide);
  }
  final pixels = element.points.map((p) => Offset(p.dx * size.width, p.dy * size.height));
  return Rect.fromLTRB(
    pixels.map((p) => p.dx).reduce(math.min),
    pixels.map((p) => p.dy).reduce(math.min),
    pixels.map((p) => p.dx).reduce(math.max),
    pixels.map((p) => p.dy).reduce(math.max),
  );
}

Rect annotationBounds(AnnotationElement element, Size size) {
  final bounds = annotationLocalBounds(element, size);
  final corners = [
    bounds.topLeft,
    bounds.topRight,
    bounds.bottomLeft,
    bounds.bottomRight,
  ].map((point) => element.transformPoint(point, size));
  return Rect.fromLTRB(
    corners.map((p) => p.dx).reduce(math.min),
    corners.map((p) => p.dy).reduce(math.min),
    corners.map((p) => p.dx).reduce(math.max),
    corners.map((p) => p.dy).reduce(math.max),
  );
}

class AnnotationPainter extends CustomPainter {
  final List<AnnotationElement> elements;

  const AnnotationPainter(this.elements);

  @override
  void paint(Canvas canvas, Size size) {
    for (final element in elements) {
      final points = element.points.map((point) => Offset(point.dx * size.width, point.dy * size.height)).toList();
      final anchor = points.first;
      canvas.save();
      canvas.translate(anchor.dx, anchor.dy);
      canvas.rotate(element.rotation);
      canvas.scale(element.scale);
      canvas.translate(-anchor.dx, -anchor.dy);
      final width = element.width * size.shortestSide / annotationWidthReferenceSide;
      final paint = Paint()
        ..color = element.color.withValues(alpha: element.opacity)
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      if (element.isText) {
        final textPainter = layoutAnnotationText(element, size);
        if (element.backgroundColor.a > 0) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(points.first & textPainter.size, const Radius.circular(4)),
            Paint()..color = element.backgroundColor.withValues(alpha: element.backgroundColor.a * element.opacity),
          );
        }
        if (element.outlineWidth > 0) {
          final outline = layoutAnnotationText(element, size, outline: true);
          outline.paint(canvas, points.first);
          outline.dispose();
        }
        textPainter.paint(canvas, points.first);
        textPainter.dispose();
        canvas.restore();
        continue;
      }

      if (element.isSticker) {
        _drawSticker(canvas, element, annotationLocalBounds(element, size));
        canvas.restore();
        continue;
      }
      if (element.tool == AnnotationTool.highlighter) {
        paint
          ..strokeWidth = width * 2.5
          ..strokeCap = StrokeCap.square;
      } else if (element.tool == AnnotationTool.brush) {
        paint.strokeWidth = width * 1.7;
      }

      if (element.tool == AnnotationTool.rectangle && points.length > 1) {
        canvas.drawRect(Rect.fromPoints(points.first, points.last), paint);
      } else if (element.tool == AnnotationTool.ellipse && points.length > 1) {
        canvas.drawOval(Rect.fromPoints(points.first, points.last), paint);
      } else if (element.tool == AnnotationTool.arrow && points.length > 1) {
        _drawArrow(canvas, points.first, points.last, paint, size.shortestSide * 8 / annotationWidthReferenceSide);
      } else if (points.length == 1) {
        canvas.drawCircle(points.first, paint.strokeWidth / 2, paint..style = PaintingStyle.fill);
      } else {
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final point in points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
      }
      canvas.restore();
    }
  }

  void _drawSticker(Canvas canvas, AnnotationElement element, Rect rect) {
    final paint = Paint()..color = element.color.withValues(alpha: element.opacity);
    final path = Path();
    if (element.text == 'heart') {
      path.moveTo(rect.center.dx, rect.bottom);
      path.cubicTo(
        rect.left - rect.width * .4,
        rect.center.dy,
        rect.left,
        rect.top - rect.height * .25,
        rect.center.dx,
        rect.top + rect.height * .25,
      );
      path.cubicTo(
        rect.right,
        rect.top - rect.height * .25,
        rect.right + rect.width * .4,
        rect.center.dy,
        rect.center.dx,
        rect.bottom,
      );
      canvas.drawPath(path, paint);
    } else if (element.text == 'star') {
      for (var i = 0; i < 10; i++) {
        final radius = rect.width * (i.isEven ? .5 : .22);
        final angle = -math.pi / 2 + i * math.pi / 5;
        final point = rect.center + Offset(math.cos(angle), math.sin(angle)) * radius;
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(path..close(), paint);
    } else if (element.text == 'smile') {
      canvas.drawOval(rect, paint);
      final ink = Paint()..color = Colors.black.withValues(alpha: element.opacity);
      canvas.drawCircle(rect.topLeft + Offset(rect.width * .32, rect.height * .35), rect.width * .06, ink);
      canvas.drawCircle(rect.topLeft + Offset(rect.width * .68, rect.height * .35), rect.width * .06, ink);
      canvas.drawArc(
        Rect.fromLTWH(rect.left + rect.width * .25, rect.top + rect.height * .35, rect.width * .5, rect.height * .4),
        0,
        math.pi,
        false,
        ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = rect.width * .05,
      );
    } else {
      final painter = layoutAnnotationText(element, rect.size / element.fontSize);
      painter.paint(canvas, rect.topLeft);
      painter.dispose();
    }
  }

  void _drawArrow(Canvas canvas, Offset start, Offset end, Paint paint, double headPadding) {
    canvas.drawLine(start, end, paint);
    final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
    final head = paint.strokeWidth * 4 + headPadding;
    final path = Path()
      ..moveTo(end.dx, end.dy)
      ..lineTo(end.dx - head * math.cos(angle - math.pi / 6), end.dy - head * math.sin(angle - math.pi / 6))
      ..moveTo(end.dx, end.dy)
      ..lineTo(end.dx - head * math.cos(angle + math.pi / 6), end.dy - head * math.sin(angle + math.pi / 6));
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant AnnotationPainter oldDelegate) => oldDelegate.elements != elements;
}
