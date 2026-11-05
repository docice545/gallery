import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/action_cell_grid.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';

class BaseBottomSheet extends ConsumerStatefulWidget {
  final List<Widget> actions;
  final DraggableScrollableController? controller;
  final List<Widget>? slivers;
  final Widget? footer;
  final double initialChildSize;
  final double minChildSize;
  final double maxChildSize;
  final bool expand;
  final bool shouldCloseOnMinExtent;
  final bool resizeOnScroll;
  final Color? backgroundColor;

  const BaseBottomSheet({
    super.key,
    required this.actions,
    this.slivers,
    this.footer,
    this.controller,
    this.initialChildSize = 0.35,
    double? minChildSize,
    this.maxChildSize = 0.65,
    this.expand = true,
    this.shouldCloseOnMinExtent = true,
    this.resizeOnScroll = true,
    this.backgroundColor,
  }) : minChildSize = minChildSize ?? 0.15;

  @override
  ConsumerState<BaseBottomSheet> createState() => _BaseDraggableScrollableSheetState();
}

class _BaseDraggableScrollableSheetState extends ConsumerState<BaseBottomSheet> {
  late DraggableScrollableController _controller;
  bool _showMore = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? DraggableScrollableController();
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A hidden action has no cell, rather than leaving an invisible gap.
    final actions = widget.actions
        .where((action) => action is! ActionWidget || action.action.create(context, ref) != null)
        .toList();
    ref.listen(timelineStateProvider, (previous, next) {
      if (!widget.resizeOnScroll || !_controller.isAttached) {
        return;
      }

      if (previous?.isInteracting != true && next.isInteracting) {
        unawaited(
          _controller.animateTo(
            widget.minChildSize,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
          ),
        );
      }
    });

    // The action-free viewer collection picker remains a regular sheet.
    if (!_showMore && widget.actions.isNotEmpty) {
      final hasDetails = actions.length > 4 || (widget.slivers?.isNotEmpty ?? false) || widget.footer != null;
      return Align(
        alignment: Alignment.bottomCenter,
        heightFactor: widget.expand ? null : 1,
        child: SelectionToolbarFrame(
          child: ActionCellGrid(
            compact: true,
            children: [
              ...actions.take(hasDetails ? 3 : 4),
              if (hasDetails)
                SelectionToolbarAction(
                  label: context.t.selection_more,
                  button: IconButton(
                    key: const ValueKey('context-selection-more'),
                    tooltip: context.t.more,
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () => setState(() => _showMore = true),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return DraggableScrollableSheet(
      controller: _controller,
      initialChildSize: widget.initialChildSize,
      minChildSize: widget.minChildSize,
      maxChildSize: widget.maxChildSize,
      snap: false,
      expand: widget.expand,
      shouldCloseOnMinExtent: widget.shouldCloseOnMinExtent,
      builder: (BuildContext context, ScrollController scrollController) {
        return _detailsSurface(
          context,
          SafeArea(
            top: false,
            child: Column(
              children: [
                Expanded(
                  child: CustomScrollView(
                    controller: scrollController,
                    slivers: [
                      SliverToBoxAdapter(
                        child: widget.actions.isEmpty
                            ? const _DragHandle()
                            : Row(
                                children: [
                                  const Expanded(child: _DragHandle()),
                                  IconButton(
                                    key: const ValueKey('context-selection-close'),
                                    tooltip: context.t.close,
                                    icon: const Icon(Icons.close),
                                    onPressed: () => setState(() => _showMore = false),
                                  ),
                                ],
                              ),
                      ),
                      if (actions.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Column(
                            children: [
                              ActionCellGrid(children: actions),
                              const Divider(indent: 16, endIndent: 16),
                              const SizedBox(height: 16),
                            ],
                          ),
                        ),
                      if (widget.slivers != null) ...widget.slivers!,
                    ],
                  ),
                ),
                if (widget.footer != null) widget.footer!,
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailsSurface(BuildContext context, Widget child) {
    if (widget.actions.isEmpty) {
      return Card(
        color: widget.backgroundColor ?? context.colorScheme.surfaceContainer,
        elevation: 3,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        margin: EdgeInsets.zero,
        child: child,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ViewerControlSurface(child: child),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: Center(
        child: SizedBox(
          width: 32,
          height: 6,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(20)),
              color: context.themeData.dividerColor.lighten(amount: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}
