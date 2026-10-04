import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';

class NativeVideoViewer extends ConsumerStatefulWidget {
  final BaseAsset asset;
  final String? localFilePath;
  final bool isCurrent;
  final bool showControls;
  final Widget image;

  /// Overrides the user's configured loop video setting
  final bool? loopOverride;

  /// Play regardless of the user's global `viewer.autoPlayVideo` setting.
  ///
  /// The memory viewer builds this widget with [showControls] `false`, so without an override a
  /// user who has autoplay disabled gets a frozen first frame and no way to start playback.
  final bool forceAutoPlay;

  /// A muted, single-pass timeline preview, isolated from asset-viewer state.
  final bool timelinePreview;
  final VoidCallback? onPreviewCompleted;

  /// Checks the scope's current token synchronously while widget removal is pending.
  final bool Function()? previewIsActive;

  const NativeVideoViewer({
    super.key,
    required this.asset,
    this.localFilePath,
    required this.image,
    this.isCurrent = false,
    this.showControls = true,
    this.loopOverride,
    this.forceAutoPlay = false,
    this.timelinePreview = false,
    this.onPreviewCompleted,
    this.previewIsActive,
  });

  @override
  ConsumerState<NativeVideoViewer> createState() => _NativeVideoViewerState();
}

class _NativeVideoViewerState extends ConsumerState<NativeVideoViewer> with WidgetsBindingObserver {
  static final _log = Logger('NativeVideoViewer');

  NativeVideoPlayerController? _controller;
  late final Future<VideoSource?> _videoSource;
  Timer? _loadTimer;
  Timer? _previewTimeout;
  bool _isVideoReady = false;
  bool _shouldPlayOnForeground = true;
  bool _previewConfigured = false;
  bool _previewFinished = false;
  bool _previewForeground = true;
  bool _previewAttached = true;
  bool _isLoading = false;
  VideoPlayerNotifier? _attachedNotifier;

  VideoPlayerNotifier get _notifier => widget.timelinePreview
      ? ref.read(timelinePreviewVideoPlayerProvider(widget.asset.id).notifier)
      : ref.read(videoPlayerProvider(widget.asset.id).notifier);

  bool get _canPreview =>
      mounted &&
      widget.isCurrent &&
      _previewAttached &&
      _previewForeground &&
      !_previewFinished &&
      (widget.previewIsActive?.call() ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.timelinePreview) {
      _previewTimeout = Timer(const Duration(seconds: 8), _finishPreview);
    }
    _videoSource = _createSource();
  }

  @override
  void deactivate() {
    if (widget.timelinePreview) {
      // Pause before child platform-view disposal; later async source/load work is stale.
      _previewAttached = false;
      unawaited(_attachedNotifier?.pause());
    }
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _previewAttached = true;
  }

  @override
  void didUpdateWidget(NativeVideoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isCurrent == oldWidget.isCurrent || _controller == null) {
      return;
    }

    if (!widget.isCurrent) {
      _loadTimer?.cancel();
      unawaited(_notifier.pause());
      return;
    }

    // Prevent unnecessary loading when swiping between assets.
    _loadTimer = Timer(const Duration(milliseconds: 200), _loadVideo);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loadTimer?.cancel();
    _previewTimeout?.cancel();
    _removeListeners();
    super.dispose();
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    if (widget.timelinePreview) {
      _previewForeground = state == AppLifecycleState.resumed;
      if (!_previewForeground) {
        _finishPreview();
      }
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        if (_shouldPlayOnForeground) {
          await _notifier.play();
        }
      case AppLifecycleState.paused:
        _shouldPlayOnForeground = await _controller?.isPlaying() ?? true;
        if (_shouldPlayOnForeground && mounted) {
          await _notifier.pause();
        }
      default:
    }
  }

  Future<VideoSource?> _createSource() async {
    if (!mounted) {
      return null;
    }

    try {
      final assetService = ref.read(assetServiceProvider);
      final videoAsset = await assetService.getAsset(widget.asset) ?? widget.asset;
      if (!mounted || (widget.timelinePreview && !_canPreview)) {
        return null;
      }

      final localFilePath = widget.localFilePath;
      if (localFilePath != null) {
        final file = File(localFilePath);
        // ignore: avoid_slow_async_io
        if (!await file.exists()) {
          throw Exception('No file found for the video');
        }

        return await VideoSource.init(
          path: CurrentPlatform.isAndroid ? file.uri.toString() : file.path,
          type: VideoSourceType.file,
        );
      }

      // Attempt to retrieve LocalAsset, falling back to remote if it cannot be found
      // photo_manager's subtype export is iOS-only. Android motion JPEG/HEIC
      // originals are images; use the server's existing extracted video pair.
      LocalAsset? localAsset = widget.timelinePreview && CurrentPlatform.isAndroid && videoAsset.isMotionPhoto
          ? null
          : await _localPlaybackAsset(videoAsset);
      if (!mounted || (widget.timelinePreview && !_canPreview)) {
        return null;
      }

      final storage = ref.read(storageRepositoryProvider);
      if (widget.timelinePreview &&
          localAsset != null &&
          !await storage.isAssetAvailableLocally(localAsset.id, withSubtype: localAsset.isMotionPhoto)) {
        localAsset = null;
      }
      if (!mounted || (widget.timelinePreview && !_canPreview)) {
        return null;
      }

      if (localAsset != null) {
        final file = localAsset.isMotionPhoto
            ? await storage.getMotionFileForAsset(localAsset)
            : await storage.getFileForAsset(localAsset.id);

        if (!mounted) {
          return null;
        }

        if (file == null) {
          throw Exception('No file found for the video');
        }

        // Pass a file:// URI so Android's Uri.parse doesn't
        // interpret characters like '#' as fragment identifiers.
        return await VideoSource.init(
          path: CurrentPlatform.isAndroid ? file.uri.toString() : file.path,
          type: VideoSourceType.file,
        );
      }

      final RemoteAsset? remoteAsset = videoAsset is RemoteAsset
          ? videoAsset
          : widget.timelinePreview && videoAsset.remoteId != null
          ? await assetService.getRemoteAsset(videoAsset.remoteId!)
          : null;
      if (!mounted || (widget.timelinePreview && !_canPreview)) {
        return null;
      }
      if (remoteAsset == null || (widget.timelinePreview && remoteAsset.livePhotoVideoId == null)) {
        throw StateError('No paired motion video available for this asset');
      }

      final serverEndpoint = Store.get(StoreKey.serverEndpoint);
      if (!context.mounted) {
        return null;
      }

      final isOriginalVideo = !widget.timelinePreview && ref.read(appConfigProvider).viewer.loadOriginalVideo;
      final String postfixUrl = isOriginalVideo ? 'original' : 'video/playback';
      final String assetId = remoteAsset.livePhotoVideoId ?? remoteAsset.id;
      final String videoUrl = '$serverEndpoint/assets/$assetId/$postfixUrl';

      return await VideoSource.init(
        path: videoUrl,
        type: VideoSourceType.network,
        headers: ApiService.getRequestHeaders(),
      );
    } catch (error) {
      _log.severe('Error creating video source for asset ${widget.asset.name}: $error');
      if (widget.timelinePreview) {
        _finishPreview();
      }
      return null;
    }
  }

  Future<LocalAsset?> _localPlaybackAsset(BaseAsset baseAsset) async {
    if (!baseAsset.hasLocal) {
      return null;
    }

    LocalAsset? localAsset;

    if (baseAsset is LocalAsset) {
      localAsset = baseAsset;
    } else {
      final localId = (baseAsset as RemoteAsset).localId;
      localAsset = localId != null ? await ref.read(assetServiceProvider).getLocalAsset(localId) : null;
    }

    if (localAsset == null) {
      _log.severe(
        'Invariant violation: asset ${baseAsset.name} (${baseAsset.localId}) is marked `hasLocal` but local asset could not be retrieved',
      );

      return null;
    }

    // Clients (local) may not correctly recognize a given asset as a motion photo. This allows for a scenario where both remote and local
    // have the same asset (hash), but only the remote properly recognizes it as a motion asset
    // If this scenario occurs, fall back to using the remote asset
    if (baseAsset.isMotionPhoto && !localAsset.isMotionPhoto) {
      // Platform mismatch for motion photo, use remote instead
      _log.warning(
        'Mismatched local and remote motion states on ${baseAsset.name} (${baseAsset.localId}), local = ${localAsset.isMotionPhoto}, remote = ${baseAsset.isMotionPhoto}',
      );

      return null;
    }

    return localAsset;
  }

  Future<void> _onPlaybackReady() async {
    if (!mounted || !widget.isCurrent || (widget.timelinePreview && (!_canPreview || !_previewConfigured))) {
      return;
    }

    _notifier.onNativePlaybackReady();

    // onPlaybackReady may be called multiple times, usually when more data
    // loads. If this is not the first time that the player has become ready, we
    // should not autoplay.
    if (_isVideoReady) {
      return;
    }

    setState(() => _isVideoReady = true);

    if (widget.timelinePreview) {
      try {
        if (_canPreview) {
          await _controller?.play();
        }
      } catch (error) {
        _log.warning('Error playing timeline preview', error);
        _finishPreview();
      }
      return;
    }

    if (ref.read(assetViewerProvider).showingDetails) {
      return;
    }

    final autoPlayVideo = ref.read(appConfigProvider).viewer.autoPlayVideo;
    if (widget.forceAutoPlay || autoPlayVideo || widget.asset.isMotionPhoto) {
      await _notifier.play();
    }
  }

  void _onPlaybackEnded() {
    if (!mounted || (widget.timelinePreview && !_canPreview)) {
      return;
    }

    _notifier.onNativePlaybackEnded();

    if (widget.timelinePreview) {
      _finishPreview();
    } else if (_controller?.playbackInfo?.status == PlaybackStatus.stopped) {
      ref.read(isPlayingMotionVideoProvider.notifier).playing = false;
    }
  }

  void _finishPreview() {
    if (!mounted || !widget.timelinePreview || !_previewAttached || _previewFinished) {
      return;
    }
    _previewFinished = true;
    _loadTimer?.cancel();
    _previewTimeout?.cancel();
    unawaited(_attachedNotifier?.pause());
    widget.onPreviewCompleted?.call();
  }

  void _onPlaybackError() {
    if (_controller?.onError.value != null) {
      _finishPreview();
    }
  }

  void _onPlaybackPositionChanged() {
    if (!mounted || (widget.timelinePreview && !_canPreview)) {
      return;
    }
    _notifier.onNativePositionChanged();
  }

  void _onPlaybackStatusChanged() {
    if (!mounted || (widget.timelinePreview && !_canPreview)) {
      return;
    }
    _notifier.onNativeStatusChanged();
  }

  void _removeListeners() {
    _controller?.onPlaybackPositionChanged.removeListener(_onPlaybackPositionChanged);
    _controller?.onPlaybackStatusChanged.removeListener(_onPlaybackStatusChanged);
    _controller?.onPlaybackReady.removeListener(_onPlaybackReady);
    _controller?.onPlaybackEnded.removeListener(_onPlaybackEnded);
    if (widget.timelinePreview) {
      _controller?.onError.removeListener(_onPlaybackError);
    }
  }

  Future<void> _loadVideo() async {
    final nc = _controller;
    if (nc == null || nc.videoSource != null || !mounted || _isLoading || (widget.timelinePreview && !_canPreview)) {
      return;
    }

    _isLoading = true;
    final source = await _videoSource;
    if (source == null || !mounted || (widget.timelinePreview && !_canPreview)) {
      _isLoading = false;
      if (source == null && widget.timelinePreview) {
        _finishPreview();
      }
      return;
    }

    if (widget.timelinePreview) {
      try {
        // Configure silence before loading, since readiness can race the load Future.
        await nc.setVolume(0);
        if (!_canPreview) {
          return;
        }
        await nc.setLoop(false);
        if (!_canPreview) {
          return;
        }
        _previewConfigured = true;
        await nc.loadVideoSource(source);
      } catch (error) {
        _log.warning('Error loading timeline preview', error);
        _finishPreview();
      } finally {
        _isLoading = false;
      }
      return;
    }

    // Grab refs to prevent reading after dispose
    final loopVideo = widget.loopOverride ?? ref.read(appConfigProvider).viewer.loopVideo;
    final localNotifier = _notifier;

    await localNotifier.load(source);
    await localNotifier.setLoop(!widget.asset.isMotionPhoto && loopVideo);
    await localNotifier.setVolume(1);
    _isLoading = false;
  }

  void _initController(NativeVideoPlayerController nc) {
    if (_controller != null || !mounted) {
      return;
    }

    final notifier = _notifier;
    _attachedNotifier = notifier;
    notifier.attachController(nc);

    nc.onPlaybackPositionChanged.addListener(_onPlaybackPositionChanged);
    nc.onPlaybackStatusChanged.addListener(_onPlaybackStatusChanged);
    nc.onPlaybackReady.addListener(_onPlaybackReady);
    nc.onPlaybackEnded.addListener(_onPlaybackEnded);
    if (widget.timelinePreview) {
      nc.onError.addListener(_onPlaybackError);
    }

    _controller = nc;

    if (widget.isCurrent) {
      unawaited(_loadVideo());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCasting = !widget.timelinePreview && ref.watch(castProvider.select((c) => c.isCasting));
    final status = widget.timelinePreview
        ? ref.watch(timelinePreviewVideoPlayerProvider(widget.asset.id).select((v) => v.status))
        : ref.watch(videoPlayerProvider(widget.asset.id).select((v) => v.status));

    return IgnorePointer(
      child: Stack(
        children: [
          if (!_isVideoReady || widget.asset.isMotionPhoto || isCasting) Center(child: widget.image),
          if (!isCasting) ...[
            Visibility.maintain(
              visible: _isVideoReady,
              child: NativeVideoPlayerView(onViewReady: _initController),
            ),
            if (!widget.timelinePreview)
              Center(
                child: AnimatedOpacity(
                  opacity: status == VideoPlaybackStatus.buffering ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 400),
                  child: const CircularProgressIndicator(),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
