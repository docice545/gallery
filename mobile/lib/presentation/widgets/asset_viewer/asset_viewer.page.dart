import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/extensions/scroll_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/download_status_floating_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_page.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_preloader.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_stack.provider.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_bottom_app_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/utils/error_handler.dart';
import 'package:immich_mobile/utils/system_ui.utils.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

@RoutePage()
class AssetViewerPage extends StatelessWidget {
  final int initialIndex;
  final TimelineService timelineService;
  final int? heroOffset;
  final RemoteAlbum? currentAlbum;

  const AssetViewerPage({
    super.key,
    required this.initialIndex,
    required this.timelineService,
    this.heroOffset,
    this.currentAlbum,
  });

  @override
  Widget build(BuildContext context) {
    // This is necessary to ensure that the timeline service is available
    // since the Timeline and AssetViewer are on different routes / Widget subtrees.
    return ProviderScope(
      overrides: [
        timelineServiceProvider.overrideWithValue(timelineService),
        currentRemoteAlbumScopedProvider.overrideWithValue(currentAlbum),
      ],
      child: AssetViewer(initialIndex: initialIndex, heroOffset: heroOffset),
    );
  }
}

class AssetViewer extends ConsumerStatefulWidget {
  final int initialIndex;
  final int? heroOffset;

  const AssetViewer({super.key, required this.initialIndex, this.heroOffset});

  @override
  ConsumerState createState() => _AssetViewerState();

  /// Sets the asset and thumbnail size before opening the viewer.
  static void setAsset(WidgetRef ref, BaseAsset asset, {Size? thumbnailSize}) {
    ref.read(assetViewerProvider.notifier).reset();

    // Hide controls by default for videos
    if (asset.isVideo) {
      ref.read(assetViewerProvider.notifier).setControls(false);
    }

    ref.read(assetViewerProvider.notifier).setAsset(asset, thumbnailSize: thumbnailSize);
  }
}

class _AssetViewerState extends ConsumerState<AssetViewer> {
  static const _viewerOverlayStyle = SystemUiOverlayStyle(
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarIconBrightness: Brightness.light,
  );

  late final _heroOffset = widget.heroOffset ?? TabsRouterScope.of(context)?.controller.activeIndex ?? 0;
  late final _pageController = PageController(initialPage: widget.initialIndex);
  late final _preloader = AssetPreloader(timelineService: ref.read(timelineServiceProvider), mounted: () => mounted);

  late int _currentPage = widget.initialIndex;
  late int _totalAssets = ref.read(timelineServiceProvider).totalAssets;
  BaseAsset? _timelineAsset;
  RemoteAsset? _retainedStackAnchor;
  int? _retainedStackPage;
  RemoteAsset? _restoreStackAsset;
  String? _autoAdvancedAssetId;
  int _reloadGeneration = 0;
  int? _pendingPage;

  StreamSubscription? _reloadSubscription;
  KeepAliveLink? _stackChildrenKeepAlive;

  int _timelineIndex(int page) => _retainedStackPage != null && page > _retainedStackPage! ? page - 1 : page;

  void _clearRetainedStack() {
    _retainedStackAnchor = null;
    _retainedStackPage = null;
    _restoreStackAsset = null;
    _autoAdvancedAssetId = null;
  }

  void _onTapNavigate(int direction) {
    final page = _pageController.page?.toInt();
    if (page == null) {
      return;
    }
    final target = page + direction;
    final maxPage = _totalAssets - 1;
    if (target >= 0 && target <= maxPage) {
      _pageController.jumpToPage(target);
      unawaited(_onAssetChanged(target));
    }
  }

  @override
  void initState() {
    super.initState();
    _timelineAsset = ref.read(timelineServiceProvider).getAssetSafe(widget.initialIndex);

    final asset = ref.read(assetViewerProvider).currentAsset;
    assert(asset != null, "Current asset should not be null when opening the AssetViewer");
    if (asset != null) {
      _stackChildrenKeepAlive = ref.read(stackChildrenNotifier(asset).notifier).ref.keepAlive();
    }

    _reloadSubscription = EventStream.shared.listen(_onEvent);

    WidgetsBinding.instance.addPostFrameCallback(_onAssetInit);

    final assetViewer = ref.read(assetViewerProvider);
    unawaited(_setSystemUIMode(assetViewer.showingControls, assetViewer.showingDetails));
  }

  @override
  void dispose() {
    _reloadGeneration++;
    _clearRetainedStack();
    _pageController.dispose();
    _preloader.dispose();
    unawaited(_reloadSubscription?.cancel());
    _stackChildrenKeepAlive?.close();

    unawaited(restoreEdgeToEdge());

    super.dispose();
  }

  // The normal onPageChange callback listens to OnScrollUpdate events, and will
  // round the current page and update whenever that value changes. In practise,
  // this means that the page will change when swiped half way, and may flip
  // whilst dragging.
  //
  // Changing the page at the end of a scroll should be more robust, and allow
  // the page to be dragged more than half way whilst keeping the current video
  // playing, and preventing the video on the next page from becoming ready
  // unnecessarily.
  bool _onScrollEnd(ScrollEndNotification notification) {
    if (notification.depth != 0) {
      return false;
    }

    final page = _pageController.page?.round();
    if (page != null && (page != _currentPage || _pendingPage != null)) {
      unawaited(_onAssetChanged(page));
    }
    return false;
  }

  void _onAssetInit(Duration timeStamp) {
    _preloader.preload(
      widget.initialIndex,
      context.sizeData,
      thumbnailSize: ref.read(assetViewerProvider).thumbnailSize,
    );
    _handleCasting();
  }

  Future<void> _onAssetChanged(int index) async {
    final generation = ++_reloadGeneration;
    _pendingPage = index;
    if (index == _retainedStackPage) {
      _pendingPage = null;
      _currentPage = index;
      return;
    }
    final sourceIndex = _timelineIndex(index);

    final asset = await ref.read(timelineServiceProvider).getAssetAsync(sourceIndex);
    if (asset == null || !mounted || generation != _reloadGeneration) {
      return;
    }

    // The viewer is closing; don't flip the current asset now. Flipping it swaps
    // the grid tile hero keys mid pop and animates the close on two tiles (#23779).
    if (!mounted || !(ModalRoute.of(context)?.isActive ?? true)) {
      return;
    }
    BaseAsset displayAsset = asset;
    var stackIndex = 0;
    final current = ref.read(assetViewerProvider).currentAsset;
    if (asset is RemoteAsset &&
        current is RemoteAsset &&
        asset.stackId != null &&
        asset.stackId == current.stackId &&
        asset.id != current.id) {
      try {
        final members = await ref.read(stackChildrenNotifier(asset).future);
        if (!mounted ||
            generation != _reloadGeneration ||
            ref.read(assetViewerProvider).currentAsset?.id != current.id ||
            ModalRoute.of(context)?.isCurrent == false) {
          return;
        }
        final memberIndex = members.indexWhere((frame) => frame.id == current.id);
        if (memberIndex >= 0) {
          displayAsset = members[memberIndex];
          stackIndex = memberIndex;
        }
      } catch (error, trace) {
        if (mounted && generation == _reloadGeneration) {
          handleError(error, stack: trace, description: 'Failed to reopen viewer stack');
        }
        return;
      }
    }
    _pendingPage = null;
    _currentPage = index;

    if (_retainedStackPage != null) {
      _clearRetainedStack();
      _currentPage = sourceIndex;
      if (_pageController.hasClients && index != sourceIndex) {
        _pageController.jumpToPage(sourceIndex);
      }
      setState(() => _totalAssets = ref.read(timelineServiceProvider).totalAssets);
    }
    if (asset is! RemoteAsset || current is! RemoteAsset || asset.stackId != current.stackId) {
      _restoreStackAsset = null;
      _autoAdvancedAssetId = null;
    }
    _timelineAsset = asset;
    ref.read(assetViewerProvider.notifier)
      ..setAsset(displayAsset)
      ..setStackIndex(stackIndex);
    _preloader.preload(sourceIndex, context.sizeData, thumbnailSize: ref.read(assetViewerProvider).thumbnailSize);
    _handleCasting();
    _stackChildrenKeepAlive?.close();
    _stackChildrenKeepAlive = ref.read(stackChildrenNotifier(asset).notifier).ref.keepAlive();
  }

  void _handleCasting() {
    if (!ref.read(castProvider).isCasting) {
      return;
    }
    final asset = ref.read(assetViewerProvider).currentAsset;
    if (asset == null) {
      return;
    }

    if (asset is RemoteAsset) {
      context.scaffoldMessenger.hideCurrentSnackBar();
      ref.read(castProvider.notifier).loadMedia(asset, false);
      return;
    }

    context.scaffoldMessenger.clearSnackBars();
    ref.read(castProvider.notifier).stop();
    context.scaffoldMessenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(
          context.t.local_asset_cast_failed,
          style: context.textTheme.bodyLarge?.copyWith(color: context.primaryColor),
        ),
      ),
    );
  }

  void _onEvent(Event event) {
    switch (event) {
      case TimelineReloadEvent():
        unawaited(_onTimelineReloadEvent());
      case ViewerReloadAssetEvent():
        _onViewerReloadEvent();
      case final ViewerStackAssetDeletedEvent event:
        unawaited(_onViewerStackAssetDeletedEvent(event));
      default:
    }
  }

  void _onViewerReloadEvent() {
    if (_totalAssets <= 1) {
      return;
    }

    final index = _pageController.page?.round() ?? 0;
    final target = index >= _totalAssets - 1 ? index - 1 : index + 1;
    unawaited(_animateToAssetPage(target));
  }

  Future<void> _animateToAssetPage(int target) async {
    if (!_pageController.hasClients) {
      return;
    }

    await _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );

    if (!mounted || !_pageController.hasClients) {
      return;
    }

    if (_currentPage != target) {
      await _onAssetChanged(target);
    }
  }

  Future<void> _onViewerStackAssetDeletedEvent(ViewerStackAssetDeletedEvent event) async {
    final currentAsset = ref.read(assetViewerProvider).currentAsset;
    if (currentAsset is! RemoteAsset || currentAsset.id != event.assetId || currentAsset.stackId != event.stackId) {
      return;
    }

    await _onTimelineReloadEvent();
  }

  Future<void> _onTimelineReloadEvent() async {
    final generation = ++_reloadGeneration;
    final timelineService = ref.read(timelineServiceProvider);
    final viewer = ref.read(assetViewerProvider);
    final currentAsset = viewer.currentAsset;
    final anchor = _retainedStackAnchor ?? _timelineAsset;
    if (currentAsset is RemoteAsset && anchor is RemoteAsset && anchor.stackId != null) {
      final provider = stackChildrenNotifier(anchor);
      final previous = ref.read(provider).valueOrNull ?? const <RemoteAsset>[];
      if (currentAsset.stackId == anchor.stackId || previous.any((asset) => asset.id == currentAsset.id)) {
        ref.invalidate(provider);
        List<RemoteAsset> stack;
        try {
          stack = await ref.read(provider.future);
          if (stack.isEmpty && previous.isNotEmpty) {
            // A two-frame stack can dissolve during sync. Its cached membership
            // still identifies the surviving standalone frame without a server request.
            final service = ref.read(assetServiceProvider);
            final refreshed = await Future.wait(previous.map(service.getAsset));
            stack = refreshed.whereType<RemoteAsset>().where((asset) => asset.deletedAt == null).toList();
          }
        } catch (error, trace) {
          if (mounted && generation == _reloadGeneration) {
            handleError(error, stack: trace, description: 'Failed to refresh viewer stack');
          }
          return;
        }
        if (!mounted ||
            generation != _reloadGeneration ||
            ref.read(assetViewerProvider).currentAsset?.id != currentAsset.id) {
          return;
        }
        if (stack.isNotEmpty) {
          var selected = stack.indexWhere((asset) => asset.id == currentAsset.id);
          final restore = _restoreStackAsset;
          if (restore != null && currentAsset.id == _autoAdvancedAssetId) {
            final restored = stack.indexWhere((asset) => asset.id == restore.id);
            if (restored >= 0) {
              selected = restored;
            }
          }
          if (selected < 0) {
            selected = math.min(viewer.stackIndex, stack.length - 1);
            _restoreStackAsset = currentAsset;
            _autoAdvancedAssetId = stack[selected].id;
          }
          final sourceIndex = stack
              .map((asset) => timelineService.getIndex(asset.heroTag))
              .whereType<int>()
              .firstOrNull;
          final target = sourceIndex ?? _currentPage.clamp(0, timelineService.totalAssets);
          final nextAnchor = sourceIndex == null ? anchor : timelineService.getAssetSafe(sourceIndex);
          // The local Timeline may already project a surviving cover before
          // StacksV1 arrives. AssetPage reads that anchor's primary-first order,
          // so preserve the chosen frame by ID, never reuse the old ordinal.
          if (nextAnchor is RemoteAsset && nextAnchor.id != anchor.id && nextAnchor.stackId != null) {
            final chosenId = stack[selected].id;
            final nextProvider = stackChildrenNotifier(nextAnchor);
            ref.invalidate(nextProvider);
            try {
              final reordered = await ref.read(nextProvider.future);
              if (!mounted ||
                  generation != _reloadGeneration ||
                  ref.read(assetViewerProvider).currentAsset?.id != currentAsset.id) {
                return;
              }
              final nextIndex = reordered.indexWhere((asset) => asset.id == chosenId);
              if (nextIndex < 0) {
                return;
              }
              stack = reordered;
              selected = nextIndex;
            } catch (error, trace) {
              if (mounted && generation == _reloadGeneration) {
                handleError(error, stack: trace, description: 'Failed to refresh promoted viewer stack');
              }
              return;
            }
          }
          if (sourceIndex == null) {
            _retainedStackAnchor = anchor;
            _retainedStackPage = target;
          } else {
            _retainedStackAnchor = null;
            _retainedStackPage = null;
            _timelineAsset = nextAnchor;
          }
          // Promotion is not a confirmed deletion. Keep the captured frame
          // until rollback restores it, or the user leaves this stack.
          if (_restoreStackAsset?.id == stack[selected].id) {
            _restoreStackAsset = null;
            _autoAdvancedAssetId = null;
          }
          ref.read(assetViewerProvider.notifier)
            ..setAsset(stack[selected])
            ..setStackIndex(selected);
          _currentPage = target;
          setState(() => _totalAssets = timelineService.totalAssets + (sourceIndex == null ? 1 : 0));
          if (_pageController.hasClients && _pageController.page?.round() != target) {
            _pageController.jumpToPage(target);
          }
          return;
        }
      }
    }
    if (!mounted || generation != _reloadGeneration) {
      return;
    }
    _clearRetainedStack();
    final totalAssets = timelineService.totalAssets;

    if (totalAssets == 0) {
      unawaited(context.maybePop());
      return;
    }

    final assetIndex = currentAsset != null ? timelineService.getIndex(currentAsset.heroTag) : null;
    final index = (assetIndex ?? _currentPage).clamp(0, totalAssets - 1);

    if (index != _currentPage) {
      _pageController.jumpToPage(index);
      unawaited(_onAssetChanged(index));
    } else if (currentAsset is RemoteAsset && currentAsset.stackId != null && assetIndex == null) {
      final timelineAsset = timelineService.getAssetSafe(index);
      if (timelineAsset is! RemoteAsset || currentAsset.stackId != timelineAsset.stackId) {
        unawaited(_onAssetChanged(index));
      }
    } else if (currentAsset != null && assetIndex == null) {
      unawaited(_onAssetChanged(index));
    }

    if (_totalAssets != totalAssets) {
      setState(() {
        _totalAssets = totalAssets;
      });
    }
  }

  Future<void> _setSystemUIMode(bool controls, bool details) {
    final immersive = !controls || (CurrentPlatform.isIOS && details);
    return immersive ? SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky) : restoreEdgeToEdge();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentUserProvider.select((user) => user?.id), (_, _) {
      _reloadGeneration++;
      _pendingPage = null;
      _clearRetainedStack();
      _timelineAsset = null;
      _stackChildrenKeepAlive?.close();
      _stackChildrenKeepAlive = null;
    });
    final showingControls = ref.watch(assetViewerProvider.select((s) => s.showingControls));
    final showingDetails = ref.watch(assetViewerProvider.select((s) => s.showingDetails));
    final isZoomed = ref.watch(assetViewerProvider.select((s) => s.isZoomed));
    final backgroundColor = showingDetails
        ? context.colorScheme.surface
        : Colors.black.withValues(alpha: ref.watch(assetViewerProvider.select((s) => s.backgroundOpacity)));

    // Listen for casting changes and send initial asset to the cast provider
    ref.listen(castProvider.select((value) => value.isCasting), (_, isCasting) {
      if (!isCasting) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleCasting();
      });
    });

    ref.listen(assetViewerProvider.select((value) => (value.showingControls, value.showingDetails)), (_, state) {
      final (controls, details) = state;
      unawaited(_setSystemUIMode(controls, details));
    });

    return AnnotatedRegion(
      value: _viewerOverlayStyle,
      child: Scaffold(
        backgroundColor: backgroundColor,
        resizeToAvoidBottomInset: false,
        appBar: const ViewerTopAppBar(),
        extendBody: true,
        extendBodyBehindAppBar: true,
        floatingActionButton: IgnorePointer(
          ignoring: !showingControls,
          child: AnimatedOpacity(
            opacity: showingControls ? 1.0 : 0.0,
            duration: Durations.short2,
            child: const DownloadStatusFloatingButton(),
          ),
        ),
        bottomNavigationBar: const ViewerBottomAppBar(),
        body: Stack(
          children: [
            NotificationListener<ScrollEndNotification>(
              onNotification: _onScrollEnd,
              child: PhotoViewGestureDetectorScope(
                axis: Axis.horizontal,
                child: PageView.builder(
                  controller: _pageController,
                  physics: isZoomed
                      ? const NeverScrollableScrollPhysics()
                      : CurrentPlatform.isIOS
                      ? const FastScrollPhysics()
                      : const FastClampingScrollPhysics(),
                  itemCount: _totalAssets,
                  itemBuilder: (context, index) => AssetPage(
                    index: _timelineIndex(index),
                    retainedAsset: index == _retainedStackPage ? _retainedStackAnchor : null,
                    heroOffset: _heroOffset,
                    onTapNavigate: _onTapNavigate,
                  ),
                ),
              ),
            ),
            if (!CurrentPlatform.isIOS)
              IgnorePointer(
                child: AnimatedContainer(
                  duration: Durations.short2,
                  color: Colors.black.withValues(alpha: showingDetails ? 0.6 : 0.0),
                  height: context.padding.top,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
