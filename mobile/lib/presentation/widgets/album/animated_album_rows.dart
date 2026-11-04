import 'package:flutter/material.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';

/// Keeps an album's real row/bin mounted during a confirmed cover flight, then
/// reflows only that row. Refresh/sorting never implies a deletion animation.
class AnimatedAlbumRows<T> extends StatefulWidget {
  const AnimatedAlbumRows({
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
  State<AnimatedAlbumRows<T>> createState() => _AnimatedAlbumRowsState<T>();
}

class _AnimatedAlbumRowsState<T> extends State<AnimatedAlbumRows<T>> {
  final _key = GlobalKey<SliverAnimatedListState>();
  late List<T> _items = List.of(widget.items);

  @override
  void didUpdateWidget(covariant AnimatedAlbumRows<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wanted = List<T>.of(widget.items);
    final ids = wanted.map(widget.keyOf).toSet();
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      final id = widget.keyOf(item);
      if (widget.heldKeys.contains(id) && ids.add(id)) {
        wanted.insert(i.clamp(0, wanted.length), item);
      }
    }
    final list = _key.currentState;
    if (list == null) {
      _items = wanted;
      return;
    }
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      final id = widget.keyOf(item);
      if (!ids.contains(id)) {
        final animated = oldWidget.heldKeys.contains(id);
        _items.removeAt(i);
        list.removeItem(
          i,
          (context, animation) => IgnorePointer(
            child: SizeTransition(sizeFactor: animation, axisAlignment: -1, child: oldWidget.builder(context, item)),
          ),
          duration: animated
              ? MediaQuery.disableAnimationsOf(context)
                    ? ghostTrapAlbumReducedReflowDuration
                    : ghostTrapAlbumReflowDuration
              : Duration.zero,
        );
      }
    }
    // Keyed reorder/update; never animate refresh as successful deletion.
    for (var i = 0; i < wanted.length; i++) {
      final id = widget.keyOf(wanted[i]);
      if (i < _items.length && widget.keyOf(_items[i]) == id) {
        _items[i] = wanted[i];
        continue;
      }
      final oldIndex = _items.indexWhere((item) => widget.keyOf(item) == id);
      if (oldIndex >= 0) {
        _items.removeAt(oldIndex);
        list.removeItem(oldIndex, (_, _) => const SizedBox.shrink(), duration: Duration.zero);
      }
      _items.insert(i, wanted[i]);
      list.insertItem(i, duration: Duration.zero);
    }
  }

  @override
  Widget build(BuildContext context) => SliverAnimatedList(
    key: _key,
    initialItemCount: _items.length,
    itemBuilder: (context, index, _) =>
        KeyedSubtree(key: ValueKey(widget.keyOf(_items[index])), child: widget.builder(context, _items[index])),
  );
}
