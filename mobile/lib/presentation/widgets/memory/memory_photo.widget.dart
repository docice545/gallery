import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

/// Uses the same image/gesture implementation as the ordinary asset viewer.
class MemoryPhoto extends StatefulWidget {
  final ImageProvider imageProvider;
  final bool isCurrent;
  final ValueChanged<bool>? onInteractionChanged;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  const MemoryPhoto({
    required this.imageProvider,
    required this.isCurrent,
    this.onInteractionChanged,
    this.onPrevious,
    this.onNext,
    super.key,
  });

  @override
  State<MemoryPhoto> createState() => _MemoryPhotoState();
}

class _MemoryPhotoState extends State<MemoryPhoto> {
  final _controller = PhotoViewController();
  final _pointers = <int>{};
  late final StreamSubscription<PhotoViewControllerValue> _subscription;
  bool _zoomed = false;
  bool _interacting = false;

  @override
  void initState() {
    super.initState();
    _subscription = _controller.outputStateStream.listen((value) {
      final initial = _controller.initialScale;
      _zoomed = initial != null && (value.scale ?? initial) > initial * 1.001;
      _notify();
    });
  }

  void _notify() {
    final interacting = _zoomed || _pointers.length > 1;
    if (interacting != _interacting) {
      _interacting = interacting;
      if (widget.isCurrent) {
        widget.onInteractionChanged?.call(interacting);
      }
    }
  }

  @override
  void didUpdateWidget(covariant MemoryPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isCurrent && !widget.isCurrent) {
      _pointers.clear();
      _zoomed = false;
      _interacting = false;
      _controller.reset();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        _pointers.add(event.pointer);
        _notify();
      },
      onPointerUp: (event) {
        _pointers.remove(event.pointer);
        _notify();
      },
      onPointerCancel: (event) {
        _pointers.remove(event.pointer);
        _notify();
      },
      child: PhotoViewGestureDetectorScope(
        axis: Axis.horizontal,
        child: PhotoView(
          imageProvider: widget.imageProvider,
          index: 0,
          controller: _controller,
          minScale: PhotoViewComputedScale.contained,
          initialScale: PhotoViewComputedScale.contained,
          backgroundDecoration: const BoxDecoration(color: Colors.transparent),
          onTapUp: (context, details, value) {
            if (!_interacting) {
              if (details.localPosition.dx < context.size!.width / 2) {
                widget.onPrevious?.call();
              } else {
                widget.onNext?.call();
              }
            }
          },
        ),
      ),
    );
  }
}
