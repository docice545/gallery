import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/utils/annotation_editor.dart';
import 'package:immich_mobile/utils/annotation_painter.dart';

/// Interactive, normalized-coordinate annotation surface used above the image preview.
class AnnotationCanvas extends StatefulWidget {
  final AnnotationEditor editor;
  final AnnotationTool tool;
  final Color color;
  final double width;
  final double opacity;
  final bool enabled;
  final bool showSelection;
  final ValueListenable<bool>? navigationActive;
  final ValueChanged<List<AnnotationElement>>? onChanged;
  final void Function(Offset point, double relativeWidth)? onTextPosition;
  final ValueChanged<AnnotationElement>? onEditText;
  final ValueNotifier<bool>? objectTransformActive;
  final String? selectedId;
  final ValueChanged<String?>? onSelectionChanged;

  const AnnotationCanvas({
    super.key,
    required this.editor,
    required this.tool,
    required this.color,
    required this.width,
    required this.opacity,
    this.enabled = true,
    this.showSelection = true,
    this.navigationActive,
    this.onChanged,
    this.onTextPosition,
    this.onEditText,
    this.objectTransformActive,
    this.selectedId,
    this.onSelectionChanged,
  });

  @override
  State<AnnotationCanvas> createState() => _AnnotationCanvasState();
}

class _AnnotationCanvasState extends State<AnnotationCanvas> {
  Offset? _start;
  List<Offset> _draftPoints = const [];
  String? _movingId;
  Offset _moveDelta = Offset.zero;
  Offset? _lastErasePoint;
  final Set<String> _erasedIds = {};
  final Set<int> _pointers = {};
  bool _gestureCancelled = false;
  Size? _surfaceSize;
  String? _selectedId;
  AnnotationElement? _resizeOriginal;
  AnnotationElement? _resizeDraft;
  final Map<int, Offset> _pointerPositions = {};
  AnnotationElement? _objectOriginal;
  AnnotationElement? _objectDraft;
  Offset _objectStartFocal = Offset.zero;
  Offset _objectStartVector = Offset.zero;

  void _select(String? id) {
    _selectedId = id;
    widget.onSelectionChanged?.call(id);
  }

  AnnotationElement? get _selected => widget.editor.elements.where((element) => element.id == _selectedId).firstOrNull;

  Offset _resizeHandle(AnnotationElement element, Size size) =>
      element.isCaption || element.rotation != 0 || element.scale != 1
      ? annotationBounds(element, size).bottomRight
      : Offset(element.points.last.dx * size.width, element.points.last.dy * size.height);

  bool get _blocked => _gestureCancelled || (widget.navigationActive?.value ?? false);

  @override
  void initState() {
    super.initState();
    _selectedId = widget.selectedId;
    widget.navigationActive?.addListener(_onNavigation);
  }

  @override
  void didUpdateWidget(covariant AnnotationCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigationActive != widget.navigationActive) {
      oldWidget.navigationActive?.removeListener(_onNavigation);
      widget.navigationActive?.addListener(_onNavigation);
    }
    if (oldWidget.selectedId != widget.selectedId) {
      _selectedId = widget.selectedId;
    }
    if (oldWidget.tool != widget.tool || oldWidget.enabled != widget.enabled || oldWidget.editor != widget.editor) {
      _clearDraft();
      _objectOriginal = null;
      _objectDraft = null;
      widget.objectTransformActive?.value = false;
      _gestureCancelled = _pointers.isNotEmpty;
      _selectedId = widget.selectedId;
    }
  }

  @override
  void dispose() {
    widget.navigationActive?.removeListener(_onNavigation);
    super.dispose();
  }

  void _clearDraft() {
    _start = null;
    _draftPoints = const [];
    _movingId = null;
    _moveDelta = Offset.zero;
    _lastErasePoint = null;
    _erasedIds.clear();
    _resizeOriginal = null;
    _resizeDraft = null;
  }

  void _onNavigation() {
    if (widget.navigationActive?.value ?? false) {
      _gestureCancelled = true;
      setState(_clearDraft);
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pointers.isEmpty) {
      _gestureCancelled = false;
    }
    _pointers.add(event.pointer);
    _pointerPositions[event.pointer] = event.localPosition;
    if (_pointers.length > 2) {
      _objectOriginal = null;
      _objectDraft = null;
      _gestureCancelled = true;
      setState(_clearDraft);
      return;
    }
    final selected = _selected;
    final size = _surfaceSize;
    if (_pointers.length == 2 &&
        widget.tool == AnnotationTool.move &&
        selected != null &&
        size != null &&
        _hitTest(_normalize(_pointerPositions.values.first, size), size) == selected.id) {
      _gestureCancelled = true;
      _clearDraft();
      _objectOriginal = selected;
      _objectDraft = selected;
      final positions = _pointerPositions.values.toList();
      _objectStartFocal = (positions[0] + positions[1]) / 2;
      _objectStartVector = positions[1] - positions[0];
      widget.objectTransformActive?.value = true;
      setState(() {});
      return;
    }
    if (_pointers.length > 1 && _objectOriginal == null) {
      _gestureCancelled = true;
      setState(_clearDraft);
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_pointerPositions.containsKey(event.pointer)) {
      return;
    }
    _pointerPositions[event.pointer] = event.localPosition;
    final original = _objectOriginal;
    final size = _surfaceSize;
    if (original == null || size == null || _pointerPositions.length != 2 || _objectStartVector.distance < 1) {
      return;
    }
    final points = _pointerPositions.values.toList();
    final vector = points[1] - points[0];
    final focal = (points[0] + points[1]) / 2;
    final factor = (vector.distance / _objectStartVector.distance).clamp(.2 / original.scale, 8 / original.scale);
    final angle = math.atan2(vector.dy, vector.dx) - math.atan2(_objectStartVector.dy, _objectStartVector.dx);
    final anchor = Offset(original.points.first.dx * size.width, original.points.first.dy * size.height);
    final delta = anchor - _objectStartFocal;
    final newAnchor =
        focal +
        Offset(
              delta.dx * math.cos(angle) - delta.dy * math.sin(angle),
              delta.dx * math.sin(angle) + delta.dy * math.cos(angle),
            ) *
            factor;
    setState(
      () => _objectDraft = original
          .translated(Offset((newAnchor.dx - anchor.dx) / size.width, (newAnchor.dy - anchor.dy) / size.height))
          .copyWith(scale: original.scale * factor, rotation: original.rotation + angle),
    );
  }

  void _pointerUp(PointerEvent event, {bool cancel = false}) {
    _pointers.remove(event.pointer);
    _pointerPositions.remove(event.pointer);
    if (cancel) {
      _objectOriginal = null;
      _objectDraft = null;
      setState(_clearDraft);
    } else if (_objectOriginal != null) {
      final draft = _objectDraft;
      if (draft != null && draft != _objectOriginal) {
        widget.editor.update(draft);
        widget.onChanged?.call(widget.editor.elements);
      }
      _objectOriginal = null;
      _objectDraft = null;
      setState(() {});
    }
    if (_pointers.isEmpty) {
      widget.objectTransformActive?.value = false;
    }
  }

  Offset _normalize(Offset local, Size size) =>
      Offset((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));

  double _relativeWidth(Size size) => widget.width * annotationWidthReferenceSide / size.shortestSide;

  void _onStart(DragStartDetails details, Size size) {
    if (_blocked) {
      return;
    }
    final point = _normalize(details.localPosition, size);
    if (widget.tool == AnnotationTool.text) {
      return;
    }
    _start = point;
    if (widget.tool == AnnotationTool.move) {
      final selected = _selected;
      if (selected != null &&
          (selected.isCaption || selected.isShape) &&
          selected.rotation == 0 &&
          selected.scale == 1 &&
          (details.localPosition - _resizeHandle(selected, size)).distance <= 20) {
        _resizeOriginal = selected;
        _resizeDraft = selected;
        return;
      }
      _movingId = _hitTest(point, size);
      _select(_movingId);
      _moveDelta = Offset.zero;
      setState(() {});
      return;
    }
    if (widget.tool == AnnotationTool.eraser) {
      _movingId = _hitTest(point, size);
      _lastErasePoint = point;
      if (_movingId case final id?) {
        _erasedIds.add(id);
      }
      return;
    }
    if (widget.tool != AnnotationTool.text) {
      _draftPoints = [point];
    }
    setState(() {});
  }

  void _onUpdate(DragUpdateDetails details, Size size) {
    final start = _start;
    if (start == null || _blocked) {
      return;
    }
    if (widget.tool == AnnotationTool.eraser) {
      final point = _normalize(details.localPosition, size);
      _collectEraserHits(point, size);
      return;
    }
    final point = _normalize(details.localPosition, size);
    if (widget.tool == AnnotationTool.move) {
      final original = _resizeOriginal;
      if (original != null) {
        final delta = point - start;
        if (original.isCaption) {
          final bounds = annotationBounds(original, size);
          if (bounds.isEmpty) {
            return;
          }
          final diagonal = bounds.bottomRight - bounds.topLeft;
          final requested = diagonal + Offset(delta.dx * size.width, delta.dy * size.height);
          final scale = (requested.dx * diagonal.dx + requested.dy * diagonal.dy) / diagonal.distanceSquared;
          final minimum = .015 / original.fontSize;
          final maximum = math.max(
            minimum,
            math.min((size.width - bounds.left) / bounds.width, (size.height - bounds.top) / bounds.height),
          );
          _resizeDraft = original.copyWith(fontSize: original.fontSize * scale.clamp(minimum, maximum));
        } else {
          final end = original.points.last + delta;
          _resizeDraft = original.copyWith(
            points: [original.points.first, Offset(end.dx.clamp(0.0, 1.0), end.dy.clamp(0.0, 1.0))],
          );
        }
      } else {
        _moveDelta = point - start;
        final moving = widget.editor.elements.where((element) => element.id == _movingId).firstOrNull;
        if (moving != null && moving.isCaption) {
          final bounds = annotationBounds(moving, size);
          // Include the rendered caption, not just its normalized anchor.
          _moveDelta = Offset(
            _moveDelta.dx.clamp(
              -bounds.left / size.width,
              (math.max(0, size.width - bounds.width) - bounds.left) / size.width,
            ),
            _moveDelta.dy.clamp(
              -bounds.top / size.height,
              (math.max(0, size.height - bounds.height) - bounds.top) / size.height,
            ),
          );
        }
      }
    } else if (widget.tool == AnnotationTool.arrow ||
        widget.tool == AnnotationTool.rectangle ||
        widget.tool == AnnotationTool.ellipse) {
      _draftPoints = [start, point];
    } else if (widget.tool != AnnotationTool.text) {
      // Bound a long stroke while keeping its shape and latest endpoint.
      final points = _draftPoints.length >= 4096
          ? [for (var index = 0; index < _draftPoints.length; index += 2) _draftPoints[index]]
          : _draftPoints;
      _draftPoints = [...points, point];
    }
    setState(() {});
  }

  void _onEnd(DragEndDetails details) {
    if (_blocked) {
      setState(_clearDraft);
      return;
    }
    if (widget.tool == AnnotationTool.eraser) {
      if (widget.editor.removeMany(_erasedIds)) {
        widget.onChanged?.call(widget.editor.elements);
      }
    } else if (widget.tool == AnnotationTool.move) {
      final id = _movingId;
      final resized = _resizeDraft;
      if (resized != null && resized != _resizeOriginal) {
        widget.editor.update(resized);
        widget.onChanged?.call(widget.editor.elements);
      } else if (id != null && _moveDelta != Offset.zero) {
        widget.editor.move(id, _moveDelta);
        widget.onChanged?.call(widget.editor.elements);
      }
    } else if (_draftPoints.isNotEmpty) {
      widget.editor.add(
        AnnotationElement(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          tool: widget.tool,
          points: _draftPoints,
          color: widget.color,
          width: _surfaceSize == null ? widget.width : _relativeWidth(_surfaceSize!),
          opacity: widget.opacity,
        ),
      );
      widget.onChanged?.call(widget.editor.elements);
    }
    setState(_clearDraft);
  }

  void _eraseAt(Offset local, Size size) {
    final id = _hitTest(_normalize(local, size), size);
    if (id != null && widget.editor.remove(id)) {
      widget.onChanged?.call(widget.editor.elements);
      setState(() {});
    }
  }

  void _collectEraserHits(Offset point, Size size) {
    final start = _lastErasePoint ?? point;
    final distance = Offset((point.dx - start.dx) * size.width, (point.dy - start.dy) * size.height).distance;
    final steps = math.max(1, (distance / 8).ceil());
    for (var index = 0; index <= steps; index++) {
      final fraction = index / steps;
      final sample = Offset(start.dx + (point.dx - start.dx) * fraction, start.dy + (point.dy - start.dy) * fraction);
      final id = _hitTest(sample, size);
      if (id != null) {
        _erasedIds.add(id);
      }
    }
    _lastErasePoint = point;
  }

  /// Adds a text annotation at an image-relative coordinate.
  void addText(String id, String text, Offset normalizedPoint) {
    if (text.trim().isEmpty) {
      return;
    }
    widget.editor.add(
      AnnotationElement(
        id: id,
        tool: AnnotationTool.text,
        points: [Offset(normalizedPoint.dx.clamp(0.0, 1.0), normalizedPoint.dy.clamp(0.0, 1.0))],
        color: widget.color,
        width: _surfaceSize == null ? widget.width : _relativeWidth(_surfaceSize!),
        opacity: widget.opacity,
        text: text.trim(),
      ),
    );
    widget.onChanged?.call(widget.editor.elements);
    setState(() {});
  }

  String? _hitTest(Offset point, Size size) {
    final pointInPixels = Offset(point.dx * size.width, point.dy * size.height);
    for (final element in widget.editor.elements.reversed) {
      if (widget.tool == AnnotationTool.eraser && !element.isDrawing) {
        continue;
      }
      final points = element.points.map((p) => Offset(p.dx * size.width, p.dy * size.height)).toList();
      if (_containsPoint(element, points, element.transformPoint(pointInPixels, size, inverse: true), size)) {
        return element.id;
      }
    }
    return null;
  }

  bool _containsPoint(AnnotationElement element, List<Offset> points, Offset point, Size size) {
    final strokeWidth = element.width * size.shortestSide / annotationWidthReferenceSide;
    final tolerance = math.max(12.0, strokeWidth * (element.tool == AnnotationTool.highlighter ? 1.25 : 1.0) + 6);
    if (element.isCaption) {
      return annotationLocalBounds(element, size).inflate(tolerance).contains(point);
    }
    if (element.tool == AnnotationTool.rectangle && points.length > 1) {
      final rect = Rect.fromPoints(points.first, points.last);
      return _nearSegment(point, rect.topLeft, rect.topRight, tolerance) ||
          _nearSegment(point, rect.topRight, rect.bottomRight, tolerance) ||
          _nearSegment(point, rect.bottomRight, rect.bottomLeft, tolerance) ||
          _nearSegment(point, rect.bottomLeft, rect.topLeft, tolerance);
    }
    if (element.tool == AnnotationTool.ellipse && points.length > 1) {
      final rect = Rect.fromPoints(points.first, points.last);
      if (rect.width < 1 || rect.height < 1) {
        return (point - rect.center).distance <= tolerance;
      }
      final rx = rect.width / 2;
      final ry = rect.height / 2;
      Offset? previous;
      for (var i = 0; i <= 48; i++) {
        final angle = math.pi * 2 * i / 48;
        final next = Offset(rect.center.dx + rx * math.cos(angle), rect.center.dy + ry * math.sin(angle));
        if (previous != null && _nearSegment(point, previous, next, tolerance)) {
          return true;
        }
        previous = next;
      }
      return false;
    }
    if (element.tool == AnnotationTool.arrow && points.length > 1) {
      if (_nearSegment(point, points.first, points.last, tolerance)) {
        return true;
      }
      final angle = math.atan2(points.last.dy - points.first.dy, points.last.dx - points.first.dx);
      final head = (element.width * 4 + 8) * size.shortestSide / annotationWidthReferenceSide;
      for (final side in [-1, 1]) {
        final end = points.last;
        final wing = Offset(
          end.dx - head * math.cos(angle + side * math.pi / 6),
          end.dy - head * math.sin(angle + side * math.pi / 6),
        );
        if (_nearSegment(point, end, wing, tolerance)) {
          return true;
        }
      }
      return false;
    }
    if (points.length == 1) {
      return (point - points.first).distance <= tolerance + strokeWidth / 2;
    }
    for (var index = 1; index < points.length; index++) {
      if (_nearSegment(point, points[index - 1], points[index], tolerance)) {
        return true;
      }
    }
    return false;
  }

  bool _nearSegment(Offset point, Offset start, Offset end, double tolerance) {
    final delta = end - start;
    final lengthSquared = delta.distanceSquared;
    if (lengthSquared == 0) {
      return (point - start).distance <= tolerance;
    }
    final fraction = (((point - start).dx * delta.dx + (point - start).dy * delta.dy) / lengthSquared).clamp(0.0, 1.0);
    return (point - (start + delta * fraction)).distance <= tolerance;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (_surfaceSize != size) {
          _surfaceSize = size;
          _objectOriginal = null;
          _objectDraft = null;
          widget.objectTransformActive?.value = false;
          _clearDraft();
          _gestureCancelled = _pointers.isNotEmpty;
        }
        final elements = <AnnotationElement>[...widget.editor.elements];
        if (_draftPoints.isNotEmpty) {
          elements.add(
            AnnotationElement(
              id: 'draft',
              tool: widget.tool,
              points: _draftPoints,
              color: widget.color,
              width: _relativeWidth(size),
              opacity: widget.opacity,
            ),
          );
        }
        if (_movingId case final id?) {
          final moving = elements.where((element) => element.id == id).firstOrNull;
          if (moving != null) {
            elements[elements.indexOf(moving)] = moving.translated(_moveDelta);
          }
        }
        if (_objectDraft case final draft?) {
          final index = elements.indexWhere((element) => element.id == draft.id);
          if (index >= 0) {
            elements[index] = draft;
          }
        }
        if (_resizeDraft case final draft?) {
          final index = elements.indexWhere((element) => element.id == draft.id);
          if (index >= 0) {
            elements[index] = draft;
          }
        }
        final selected = elements.where((element) => element.id == _selectedId).firstOrNull;
        final showSelection = widget.enabled && widget.showSelection && widget.tool == AnnotationTool.move;
        return IgnorePointer(
          ignoring: !widget.enabled,
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _pointerMove,
            onPointerUp: _pointerUp,
            onPointerCancel: (event) => _pointerUp(event, cancel: true),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              dragStartBehavior: DragStartBehavior.down,
              onPanStart: (details) => _onStart(details, size),
              onPanUpdate: (details) => _onUpdate(details, size),
              onPanEnd: _onEnd,
              onPanCancel: () => setState(_clearDraft),
              onTapUp: widget.tool == AnnotationTool.text
                  ? (details) {
                      if (!_blocked) {
                        final point = _normalize(details.localPosition, size);
                        final id = _hitTest(point, size);
                        final element = widget.editor.elements.where((element) => element.id == id).firstOrNull;
                        if (element != null && element.isText && widget.onEditText != null) {
                          widget.onEditText!(element);
                        } else {
                          widget.onTextPosition?.call(point, _relativeWidth(size));
                        }
                      }
                    }
                  : widget.tool == AnnotationTool.eraser
                  ? (details) {
                      if (!_blocked) {
                        _eraseAt(details.localPosition, size);
                      }
                    }
                  : widget.tool == AnnotationTool.move
                  ? (details) {
                      if (!_blocked) {
                        setState(() => _select(_hitTest(_normalize(details.localPosition, size), size)));
                      }
                    }
                  : null,
              child: SizedBox.fromSize(
                size: size,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: CustomPaint(size: size, painter: AnnotationPainter(elements)),
                    ),
                    if (showSelection && selected != null && selected.isText && widget.onEditText != null)
                      Positioned(
                        left: annotationBounds(selected, size).left.clamp(0.0, math.max(0.0, size.width - 48)),
                        top: (annotationBounds(selected, size).top - 52).clamp(0.0, math.max(0.0, size.height - 48)),
                        child: IconButton.filled(
                          key: const Key('annotation-edit-text'),
                          tooltip: context.t.edit,
                          onPressed: () {
                            if (!_blocked) {
                              widget.onEditText!(selected);
                            }
                          },
                          icon: const Icon(Icons.edit, size: 20),
                        ),
                      ),
                    if (showSelection && selected != null && (selected.isCaption || selected.isShape)) ...[
                      Positioned.fromRect(
                        rect: annotationBounds(selected, size),
                        child: IgnorePointer(
                          child: DecoratedBox(
                            key: const Key('annotation-selection'),
                            decoration: BoxDecoration(border: Border.all(color: Colors.white)),
                          ),
                        ),
                      ),
                      Positioned(
                        left: _resizeHandle(selected, size).dx - 8,
                        top: _resizeHandle(selected, size).dy - 8,
                        width: 16,
                        height: 16,
                        child: const IgnorePointer(
                          child: DecoratedBox(
                            key: Key('annotation-resize-handle'),
                            decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
