import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';

/// Annotation stroke widths are fractions of the 360 logical-pixel design side.
const annotationWidthReferenceSide = 360.0;

TextPainter layoutAnnotationText(AnnotationElement element, Size size) => TextPainter(
  text: TextSpan(
    text: element.text,
    style: TextStyle(
      color: element.color.withValues(alpha: element.opacity),
      fontSize: element.fontSize * size.shortestSide,
      fontWeight: FontWeight.w600,
    ),
  ),
  textDirection: ui.TextDirection.ltr,
)..layout(maxWidth: size.width * .8 * element.fontSize / .06);

class AnnotationPainter extends CustomPainter {
  final List<AnnotationElement> elements;

  const AnnotationPainter(this.elements);

  @override
  void paint(Canvas canvas, Size size) {
    for (final element in elements) {
      final points = element.points.map((point) => Offset(point.dx * size.width, point.dy * size.height)).toList();
      final width = element.width * size.shortestSide / annotationWidthReferenceSide;
      final paint = Paint()
        ..color = element.color.withValues(alpha: element.opacity)
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      if (element.isText) {
        final textPainter = layoutAnnotationText(element, size);
        textPainter.paint(canvas, points.first);
        textPainter.dispose();
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
