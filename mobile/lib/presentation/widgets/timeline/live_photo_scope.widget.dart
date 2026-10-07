import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_framing.dart';
import 'package:immich_mobile/presentation/widgets/images/timeline_thumbnail_request.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_autoplay.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/photos_filter/filter_sheet.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:logging/logging.dart';

typedef LivePhotoPreviewBuilder = Widget Function(BaseAsset asset, VoidCallback onCompleted);

/// Opt-in scope used only by the main Photos timeline. Cached/offscreen grid
/// rows register geometry, not players. Visibility is sampled after layout and
/// after scroll settles; there is no per-tile polling or video prefetch.
class TimelineLivePhotoScope extends ConsumerStatefulWidget {
  const TimelineLivePhotoScope({super.key, required this.child, this.previewBuilder});

  final Widget child;
  final LivePhotoPreviewBuilder? previewBuilder;

  static _TimelineLivePhotoScopeState? _maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LivePhotoScope>()?.state;

  @override
  ConsumerState<TimelineLivePhotoScope> createState() => _TimelineLivePhotoScopeState();
}

class _TimelineLivePhotoScopeState extends ConsumerState<TimelineLivePhotoScope> with WidgetsBindingObserver {
  final controller = LivePhotoAutoplayController(enabled: false);
  final Map<Object, _LivePhotoRegistration> _tiles = {};
  RoutingController? _router;
  TabsRouter? _tabsRouter;
  RouteData? _routeData;
  ModalRoute<dynamic>? _modalRoute;
  bool _foreground = true;
  bool _scrolling = false;
  final Set<int> _pointers = {};
  bool _refreshScheduled = false;
  final Map<String, String> _lastDiagnostics = {};
  static final _log = Logger('TimelineLivePhoto');
  late bool _settingEnabled;
  late bool _selecting;
  late bool _filterSheetVisible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settingEnabled = ref.read(appConfigProvider).timeline.autoplayLivePhotos;
    final selection = ref.read(multiSelectProvider);
    _selecting = selection.isEnabled || selection.forceEnable;
    _filterSheetVisible = ref.read(photosFilterSheetProvider) != FilterSheetVisibility.hidden;
    ref.listenManual(appConfigProvider.select((config) => config.timeline.autoplayLivePhotos), (_, enabled) {
      _settingEnabled = enabled;
      _updateEnabled();
    });
    ref.listenManual(multiSelectProvider.select((s) => s.isEnabled || s.forceEnable), (_, selecting) {
      _selecting = selecting;
      _updateEnabled();
    });
    ref.listenManual(photosFilterSheetProvider, (_, visibility) {
      _filterSheetVisible = visibility != FilterSheetVisibility.hidden;
      _updateEnabled();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _modalRoute = ModalRoute.of(context);
    _routeData = context.findAncestorWidgetOfExactType<RouteDataScope>()?.routeData;
    final router = _routeData?.router.root;
    if (router != _router) {
      _router?.removeListener(_updateEnabled);
      _router = router;
      _router?.addListener(_updateEnabled);
    }
    final tabs = TabsRouterScope.of(context, watch: true)?.controller;
    if (tabs != _tabsRouter) {
      _tabsRouter?.removeListener(_updateEnabled);
      _tabsRouter = tabs;
      _tabsRouter?.addListener(_updateEnabled);
    }
    // Dependency changes can occur during an ancestor build. Apply state after
    // layout so an active tile is never marked dirty while that build runs.
    refresh();
  }

  void _updateEnabled() {
    if (!mounted) {
      return;
    }
    final active =
        (_modalRoute?.isCurrent ?? true) && (_routeData?.isActive ?? true) && TickerMode.valuesOf(context).enabled;
    controller.setEnabled(_settingEnabled && !_selecting && !_filterSheetVisible && _foreground && active);
    refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateEnabled();
  }

  void register(Object token, BaseAsset asset, BuildContext tileContext) {
    _tiles[token] = _LivePhotoRegistration(asset, tileContext);
    refresh();
  }

  void unregister(Object token) {
    _tiles.remove(token);
    controller.unregister(token);
    refresh();
  }

  void pausePreview(BaseAsset asset) {
    if (mounted && widget.previewBuilder == null) {
      unawaited(ref.read(timelinePreviewVideoPlayerProvider(asset.id).notifier).pause());
    }
  }

  void refresh() {
    if (_refreshScheduled || !mounted) {
      return;
    }
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (!mounted) {
        return;
      }
      final active =
          (_modalRoute?.isCurrent ?? true) && (_routeData?.isActive ?? true) && TickerMode.valuesOf(context).enabled;
      final enabled = _settingEnabled && !_selecting && !_filterSheetVisible && _foreground && active;
      _traceDecision(
        'state',
        'enabled=$enabled setting=$_settingEnabled selecting=$_selecting '
            'filter=$_filterSheetVisible foreground=$_foreground route=$active scrolling=$_scrolling',
      );
      controller.setEnabled(enabled);
      // There is no active player while scrolling/touching. Defer geometry work
      // until settling so it does not compete with rendering the scroll frames.
      if (enabled && !_scrolling && _pointers.isEmpty) {
        _measureTiles();
      }
    });
  }

  void _measureTiles() {
    final scopeBox = context.findRenderObject();
    if (scopeBox is! RenderBox || !scopeBox.hasSize) {
      _traceDecision('geometry', 'geometry-unavailable');
      controller.updateCandidates(const []);
      return;
    }
    final bounds = scopeBox.localToGlobal(Offset.zero) & scopeBox.size;
    final media = MediaQuery.of(context);
    // Exclude the system insets and bottom navigation from the visible viewport.
    final screen = Rect.fromLTRB(0, media.padding.top, media.size.width, media.size.height - media.padding.bottom);
    final viewport = bounds.intersect(screen);
    final candidates = <LivePhotoCandidate>[];
    for (final entry in _tiles.entries) {
      final tile = entry.value;
      if (!tile.context.mounted) {
        continue;
      }
      final box = tile.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) {
        continue;
      }
      final rect = box.localToGlobal(Offset.zero) & box.size;
      candidates.add(
        LivePhotoCandidate(
          token: entry.key,
          asset: tile.asset,
          visibleFraction: livePhotoVisibleFraction(rect, viewport),
          distanceFromCenter: (rect.center - viewport.center).distanceSquared,
        ),
      );
    }
    final live = candidates.where((c) => c.asset.isImage && c.asset.isMotionPhoto);
    // One record per changed settled measurement; no IDs, filenames or per-frame
    // playback logs. Helps distinguish ineligibility from source/decoder failure.
    _traceDecision(
      'geometry',
      'registered=${candidates.length} live=${live.length} '
          'visible=${live.where((c) => c.visibleFraction >= livePhotoVisibilityThreshold).length}',
    );
    controller.updateCandidates(candidates);
  }

  void _traceDecision(String name, String value) {
    if (_lastDiagnostics[name] != value) {
      _lastDiagnostics[name] = value;
      _log.info('Timeline motion: $value');
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _scrolling = true;
      controller.setScrolling(true);
      _updateViewport(notification.metrics);
    } else if (notification is ScrollUpdateNotification || notification is OverscrollNotification) {
      // Includes programmatic jumps from the timeline scrubber.
      _scrolling = true;
      controller.setScrolling(true);
      _updateViewport(notification.metrics);
      refresh();
    } else if (notification is ScrollEndNotification) {
      _scrolling = false;
      _updateViewport(notification.metrics);
      controller.setScrolling(_pointers.isNotEmpty);
      refresh();
    }
    return false;
  }

  void _updateViewport(ScrollMetrics metrics, {bool fromScroll = true}) {
    controller.updateViewport(
      // Rubber-band overscroll does not form a new area of the timeline.
      scrollOffset: metrics.pixels.clamp(metrics.minScrollExtent, metrics.maxScrollExtent),
      viewportExtent: metrics.viewportDimension,
      fromScroll: fromScroll,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router?.removeListener(_updateEnabled);
    _tabsRouter?.removeListener(_updateEnabled);
    _tiles.clear();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    refresh();
    return _LivePhotoScope(
      state: this,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
            _updateViewport(notification.metrics, fromScroll: false);
            refresh();
          }
          return false;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Listener(
            onPointerDown: (event) {
              _pointers.add(event.pointer);
              controller.setScrolling(true);
            },
            onPointerUp: (event) {
              _pointers.remove(event.pointer);
              controller.setScrolling(_scrolling || _pointers.isNotEmpty);
              refresh();
            },
            onPointerCancel: (event) {
              _pointers.remove(event.pointer);
              controller.setScrolling(_scrolling || _pointers.isNotEmpty);
              refresh();
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _LivePhotoRegistration {
  const _LivePhotoRegistration(this.asset, this.context);
  final BaseAsset asset;
  final BuildContext context;
}

class _LivePhotoScope extends InheritedWidget {
  const _LivePhotoScope({required this.state, required super.child});
  final _TimelineLivePhotoScopeState state;

  @override
  bool updateShouldNotify(_LivePhotoScope oldWidget) => oldWidget.state != state;
}

/// Overlay outside the thumbnail Hero, below the existing badges. It neither
/// participates in hit testing nor changes selection, navigation or tile size.
class TimelineLivePhotoTile extends StatefulWidget {
  const TimelineLivePhotoTile({
    super.key,
    required this.asset,
    this.faces = const [],
    this.framingImageSize,
    this.requireMatchingFraming = false,
  });
  final BaseAsset asset;
  final List<Rect> faces;
  final Size? framingImageSize;
  final bool requireMatchingFraming;

  @override
  State<TimelineLivePhotoTile> createState() => _TimelineLivePhotoTileState();
}

class _TimelineLivePhotoTileState extends State<TimelineLivePhotoTile> {
  _TimelineLivePhotoScopeState? _scope;
  final _token = Object();
  bool _isActive = false;
  bool _rebuildScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = TimelineLivePhotoScope._maybeOf(context);
    if (_scope != scope) {
      _scope?.controller.removeListener(_onPlaybackChanged);
      _scope?.unregister(_token);
      _scope = scope;
      scope?.controller.addListener(_onPlaybackChanged);
    }
    _scope?.register(_token, widget.asset, context);
  }

  @override
  void didUpdateWidget(TimelineLivePhotoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset != widget.asset) {
      _scope?.unregister(_token);
      _scope?.register(_token, widget.asset, context);
    }
  }

  void _onPlaybackChanged() {
    final active = _scope?.controller.activeToken == _token;
    if (!mounted || active == _isActive) {
      return;
    }
    _isActive = active;
    if (!active) {
      _scope?.pausePreview(widget.asset);
    }
    // Removing/replacing a cached row can revoke the lease during finalizeTree.
    // Only the changed tile rebuilds, and never while Flutter locks the tree.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_rebuildScheduled) {
        return;
      }
      _rebuildScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _rebuildScheduled = false;
        if (mounted) {
          setState(() {});
        }
      });
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _scope?.controller.removeListener(_onPlaybackChanged);
    _scope?.unregister(_token);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope;
    if (scope == null || scope.controller.activeToken != _token) {
      return const SizedBox.expand();
    }
    void onCompleted() => scope.controller.complete(_token);
    if (widget.requireMatchingFraming && widget.framingImageSize == null) {
      // Edited/unknown still geometry cannot be registered to the motion frame.
      // Consume only this viewport's reservation; never try the next live photo.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scope == scope) {
          _TimelineLivePhotoScopeState._log.info('Timeline motion: skipped:still-geometry-unavailable');
          onCompleted();
        }
      });
      return const SizedBox.expand();
    }
    return IgnorePointer(
      child:
          scope.widget.previewBuilder?.call(widget.asset, onCompleted) ??
          ClipRect(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = widget.asset.width;
                final height = widget.asset.height;
                final hasDimensions = width != null && height != null && width > 0 && height > 0;
                final imageSize =
                    widget.framingImageSize ?? (hasDimensions ? Size(width.toDouble(), height.toDouble()) : null);
                final aspect = imageSize != null ? imageSize.aspectRatio : constraints.maxWidth / constraints.maxHeight;
                final tileAspect = constraints.maxWidth / constraints.maxHeight;
                // Size the platform view in logical tile pixels, never in the
                // original photo's multi-megapixel dimensions.
                final previewWidth = aspect > tileAspect ? constraints.maxHeight * aspect : constraints.maxWidth;
                final previewHeight = aspect > tileAspect ? constraints.maxHeight : constraints.maxWidth / aspect;
                final framing = faceAwareThumbnailFraming(
                  imageSize: imageSize ?? Size(previewWidth, previewHeight),
                  viewportSize: Size(constraints.maxWidth, constraints.maxHeight),
                  faces: widget.faces,
                );
                return FittedBox(
                  fit: framing.fit,
                  alignment: framing.alignment,
                  child: SizedBox(
                    width: previewWidth,
                    height: previewHeight,
                    child: NativeVideoViewer(
                      key: ValueKey(widget.asset.heroTag),
                      asset: widget.asset,
                      image: const SizedBox.expand(),
                      isCurrent: true,
                      showControls: false,
                      timelinePreview: true,
                      timelinePreviewImageSize: widget.framingImageSize,
                      timelinePreviewAlignment: framing.alignment,
                      timelinePreviewRequiredSize: widget.framingImageSize == null
                          ? null
                          : buildTimelineThumbnailRequest(
                              viewportSize: Size(constraints.maxWidth, constraints.maxHeight),
                              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                              imageSize: widget.framingImageSize,
                              faces: widget.faces,
                            ).requiredSize,
                      previewIsActive: () => scope.controller.activeToken == _token,
                      onPreviewCompleted: onCompleted,
                    ),
                  ),
                );
              },
            ),
          ),
    );
  }
}
