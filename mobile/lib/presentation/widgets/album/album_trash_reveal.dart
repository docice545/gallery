import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';

/// A reveal gesture is navigation, never consent to delete. Only the exposed
/// button owns [onTrash]; the row keeps its identity and extent until real ACK.
class AlbumTrashReveal extends StatefulWidget {
  const AlbumTrashReveal({super.key, required this.child, required this.onTrash});

  final Widget child;
  final Future<void> Function() onTrash;

  @override
  State<AlbumTrashReveal> createState() => _AlbumTrashRevealState();
}

class _AlbumTrashRevealState extends State<AlbumTrashReveal> with SingleTickerProviderStateMixin {
  static const _extent = 64.0;
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
  bool _busy = false;

  void _settle(bool open) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = open ? 1 : 0;
    } else {
      _controller.animateTo(open ? 1 : 0, curve: Curves.easeOutCubic);
    }
  }

  Future<void> _trash() async {
    if (_busy || _controller.value < .99) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.onTrash();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _settle(false);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) => Stack(
        alignment: Alignment.centerRight,
        children: [
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: ExcludeSemantics(
                excluding: _controller.value < .99,
                child: IgnorePointer(
                  ignoring: _controller.value < .99 || _busy,
                  child: SizedBox(
                    width: _extent,
                    child: Center(
                      child: FotoIconButton(
                        kind: FotoIconKind.trash,
                        label: context.t.delete_album,
                        destructive: true,
                        onPressed: _busy ? null : _trash,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(-_extent * _controller.value, 0),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: _busy
                  ? null
                  : (details) => _controller.value = (_controller.value - details.delta.dx / _extent).clamp(0, 1),
              onHorizontalDragEnd: _busy
                  ? null
                  : (details) => _settle(
                      (details.primaryVelocity ?? 0) < -200 ||
                          ((details.primaryVelocity ?? 0) <= 200 && _controller.value >= .5),
                    ),
              onHorizontalDragCancel: _busy ? null : () => _settle(_controller.value >= .5),
              onTap: _busy || _controller.value == 0 ? null : () => _settle(false),
              child: AbsorbPointer(
                absorbing: _controller.value != 0 || _busy,
                child: SizedBox(
                  width: double.infinity,
                  child: Material(color: Theme.of(context).colorScheme.surface, child: child),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
