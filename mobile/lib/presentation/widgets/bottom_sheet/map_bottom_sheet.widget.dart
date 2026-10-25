import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/general_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_route_scope.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';

/// A persistent map panel: only the count and handle occupy the map until the
/// user expands it. The header owns the sheet's drag controller; the timeline
/// keeps its own scroll controller so its list can scroll normally when open.
class MapBottomSheet extends StatefulWidget {
  final Key? sheetKey;
  final DraggableScrollableController? controller;

  const MapBottomSheet({super.key, this.sheetKey, this.controller});

  @override
  State<MapBottomSheet> createState() => _MapBottomSheetState();
}

class _MapBottomSheetState extends State<MapBottomSheet> {
  DraggableScrollableController? _ownedController;

  DraggableScrollableController get _controller =>
      widget.controller ?? (_ownedController ??= DraggableScrollableController());

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final countStyle = context.themeData.textTheme.titleSmall;
        final countLineHeight =
            MediaQuery.textScalerOf(context).scale(countStyle?.fontSize ?? 14) * (countStyle?.height ?? 1.4);
        final headerHeight = math.max(64.0, 20 + countLineHeight * 2);
        final minSize = ((headerHeight + MediaQuery.paddingOf(context).bottom) / constraints.maxHeight).clamp(
          0.01,
          0.95,
        );
        final maxSize = math.max(minSize, 0.85);
        return DraggableScrollableSheet(
          key: widget.sheetKey,
          controller: _controller,
          initialChildSize: minSize,
          minChildSize: minSize,
          maxChildSize: maxSize,
          shouldCloseOnMinExtent: false,
          snap: true,
          builder: (context, dragController) => Material(
            color: context.themeData.colorScheme.surface,
            elevation: 3,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            clipBehavior: Clip.antiAlias,
            child: MapBottomSheetTimeline(
              headerHeight: headerHeight,
              dragController: dragController,
              onToggle: () {
                final target = _controller.size > minSize + 0.02 ? minSize : maxSize;
                unawaited(
                  _controller.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeInOut),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class MapBottomSheetTimeline extends StatelessWidget {
  final ScrollController? dragController;
  final double headerHeight;
  final VoidCallback? onToggle;

  const MapBottomSheetTimeline({super.key, this.dragController, this.headerHeight = 64, this.onToggle});

  @override
  Widget build(BuildContext context) {
    return TimelineRouteScope(
      timelineServiceBuilder: (ref, scope, groupBy) {
        final user = ref.watch(currentUserProvider);
        if (user == null) {
          throw Exception('User must be logged in to access the map timeline');
        }

        final withPartners = ref.watch(mapStateProvider.select((s) => s.withPartners));
        final users = withPartners ? ref.watch(timelineUsersProvider).valueOrNull ?? [user.id] : [user.id];

        final optionsController = StreamController<TimelineMapOptions>.broadcast();
        ref.onDispose(optionsController.close);

        var currentOptions = ref.read(mapStateProvider).toOptions();

        ref.listen(mapStateProvider.select((state) => state.toOptions()), (_, newOptions) {
          currentOptions = newOptions;
          optionsController.add(newOptions);
        });

        return ref
            .watch(timelineFactoryProvider)
            .geographicMap(
              users,
              user.id,
              () => currentOptions,
              optionsController.stream,
              groupBy: groupBy,
              temporalScope: scope,
            );
      },
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // While collapsed the grid is unmounted, avoiding invisible image
              // requests and a floating grouping selector over the map.
              final expanded = constraints.maxHeight > headerHeight + 96;
              return Column(
                children: [
                  SizedBox(
                    height: math.min(headerHeight, constraints.maxHeight),
                    child: SingleChildScrollView(
                      controller: dragController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: SizedBox(
                        height: headerHeight,
                        child: Semantics(
                          button: onToggle != null,
                          expanded: expanded,
                          child: InkWell(
                            key: const Key('map-panel-toggle'),
                            onTap: onToggle,
                            child: Column(
                              children: [
                                const SizedBox(height: 8),
                                Container(
                                  key: const Key('map-panel-drag-handle'),
                                  width: 32,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: context.themeData.colorScheme.onSurfaceVariant,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    child: Row(
                                      children: [
                                        const Expanded(child: _MapAssetCount()),
                                        if (onToggle != null)
                                          Icon(
                                            expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                                            semanticLabel: expanded ? context.t.collapse : context.t.expand,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (expanded)
                    const Expanded(
                      child: Timeline(
                        key: Key('map-panel-timeline'),
                        appBar: null,
                        bottomSheet: GeneralBottomSheet(minChildSize: 0.23, expand: false),
                        withScrubber: false,
                        withGroupingPill: true,
                        dockGroupingPill: true,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MapAssetCount extends ConsumerStatefulWidget {
  const _MapAssetCount();

  @override
  ConsumerState<_MapAssetCount> createState() => _MapAssetCountState();
}

class _MapAssetCountState extends ConsumerState<_MapAssetCount> {
  StreamSubscription? _reloadSubscription;

  @override
  void initState() {
    super.initState();
    _reloadSubscription = EventStream.shared.listen<TimelineReloadEvent>((_) => setState(() {}));
  }

  @override
  void dispose() {
    unawaited(_reloadSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = ref.watch(timelineServiceProvider.select((s) => s.totalAssets));
    return Text(
      context.t.map_assets_in_bounds(count: count),
      key: const Key('map-panel-asset-count'),
      style: context.themeData.textTheme.titleSmall,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
