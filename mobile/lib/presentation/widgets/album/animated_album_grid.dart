import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';

/// Retains a confirmed operation's actual target until the cover flight ends,
/// then interpolates surviving cards into the native SliverGrid geometry.
class AnimatedAlbumGrid<T> extends StatefulWidget {
  const AnimatedAlbumGrid({
    super.key,
    required this.items,
    required this.keyOf,
    required this.heldKeys,
    required this.builder,
  });
  final List<T> items;
  final String Function(T) keyOf;
  final Set<String> heldKeys;
  final Widget Function(BuildContext, T) builder;

  @override
  State<AnimatedAlbumGrid<T>> createState() => _AnimatedAlbumGridState<T>();
}

class _AnimatedAlbumGridState<T> extends State<AnimatedAlbumGrid<T>> with SingleTickerProviderStateMixin {
  late List<T> _items = List.of(widget.items);
  late final _controller = AnimationController(vsync: this, value: 1);
  Map<String, int> _previous = {};

  @override
  void didUpdateWidget(covariant AnimatedAlbumGrid<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wanted = List<T>.of(widget.items);
    final ids = wanted.map(widget.keyOf).toSet();
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (widget.heldKeys.contains(widget.keyOf(item)) && ids.add(widget.keyOf(item))) {
        wanted.insert(i.clamp(0, wanted.length), item);
      }
    }
    final confirmedRemoval = _items.any(
      (item) => oldWidget.heldKeys.contains(widget.keyOf(item)) && !ids.contains(widget.keyOf(item)),
    );
    if (confirmedRemoval) {
      _previous = {for (var i = 0; i < _items.length; i++) widget.keyOf(_items[i]): i};
      _controller.duration = MediaQuery.disableAnimationsOf(context)
          ? ghostTrapAlbumReducedReflowDuration
          : ghostTrapAlbumReflowDuration;
      _controller.forward(from: 0);
    }
    _items = wanted;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final columns = math.max(1, (constraints.crossAxisExtent / 250).ceil());
      final width = (constraints.crossAxisExtent - 4 * (columns - 1)) / columns;
      final height = width / .7;
      Offset origin(int index) => Offset((index % columns) * (width + 4), (index ~/ columns) * (height + 4));
      return SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 250,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: .7,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final item = _items[index];
            final id = widget.keyOf(item);
            final delta = origin(_previous[id] ?? index) - origin(index);
            return AnimatedBuilder(
              key: ValueKey(id),
              animation: _controller,
              child: widget.builder(context, item),
              builder: (_, child) => Transform.translate(
                offset: delta * (1 - Curves.easeOutCubic.transform(_controller.value)),
                child: child,
              ),
            );
          },
          childCount: _items.length,
          findChildIndexCallback: (key) {
            final index = _items.indexWhere((item) => ValueKey(widget.keyOf(item)) == key);
            return index < 0 ? null : index;
          },
        ),
      );
    },
  );
}
