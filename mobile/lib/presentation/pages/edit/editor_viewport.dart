import 'package:flutter/material.dart';

/// A shared image/annotation transform. Raw pointers keep two-finger navigation
/// independent of the crop and markup recognizers, even after drawing starts.
class EditorViewport extends StatefulWidget {
  final Size contentSize;
  final ValueNotifier<bool> navigationActive;
  final Widget child;

  const EditorViewport({super.key, required this.contentSize, required this.navigationActive, required this.child});

  @override
  State<EditorViewport> createState() => _EditorViewportState();
}

class _EditorViewportState extends State<EditorViewport> {
  final Map<int, Offset> _pointers = {};
  Size? _viewportSize;
  Size? _contentSize;
  double _scale = 1;
  Offset _offset = Offset.zero;
  double? _startDistance;
  double _startScale = 1;
  Offset _anchor = Offset.zero;
  bool _interrupted = false;

  void _rebase() {
    if (_pointers.length < 2 || _interrupted) {
      _startDistance = null;
      return;
    }
    final points = _pointers.values.take(2).toList();
    _startDistance = (points[1] - points[0]).distance;
    _startScale = _scale;
    final focalPoint = (points[0] + points[1]) / 2;
    _anchor = (focalPoint - _viewportSize!.center(Offset.zero) - _offset) / _scale;
  }

  void _down(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length >= 2) {
      widget.navigationActive.value = true;
    }
    _rebase();
  }

  void _move(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) {
      return;
    }
    _pointers[event.pointer] = event.localPosition;
    final distance = _startDistance;
    if (_pointers.length < 2 || distance == null || distance < 1 || _interrupted) {
      return;
    }
    final points = _pointers.values.take(2).toList();
    final focalPoint = (points[0] + points[1]) / 2;
    setState(() {
      _scale = (_startScale * (points[1] - points[0]).distance / distance).clamp(1.0, 8.0);
      final requested = focalPoint - _viewportSize!.center(Offset.zero) - _anchor * _scale;
      // Center undersized axes and prevent panning an image completely away.
      final maxX = ((widget.contentSize.width * _scale - _viewportSize!.width) / 2).clamp(0.0, double.infinity);
      final maxY = ((widget.contentSize.height * _scale - _viewportSize!.height) / 2).clamp(0.0, double.infinity);
      _offset = Offset(requested.dx.clamp(-maxX, maxX), requested.dy.clamp(-maxY, maxY));
    });
  }

  void _up(PointerEvent event) {
    _pointers.remove(event.pointer);
    _rebase();
    // Do not resume drawing with the remaining finger after a pinch.
    if (_pointers.isEmpty) {
      _interrupted = false;
      widget.navigationActive.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_viewportSize != constraints.biggest || _contentSize != widget.contentSize) {
          _viewportSize = constraints.biggest;
          _contentSize = widget.contentSize;
          _scale = 1;
          _offset = Offset.zero;
          _startDistance = null;
          _interrupted = _pointers.isNotEmpty;
        }
        return ClipRect(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            child: Center(
              child: Transform(
                key: const Key('editor-zoom-transform'),
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                  ..scaleByDouble(_scale, _scale, 1, 1),
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }
}
