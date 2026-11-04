import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const ghostTrapDuration = Duration(milliseconds: 640);
const ghostTrapReducedDuration = Duration(milliseconds: 180);
const ghostTrapAlbumReflowDuration = Duration(milliseconds: 120);
const ghostTrapAlbumReducedReflowDuration = Duration(milliseconds: 60);

enum GhostTrashKind { server, device, album }

String ghostAlbumKey(String scope, String id) => '$scope-album:$id';
String ghostAlbumCoverKey(String scope, String albumId, String assetId) => '${ghostAlbumKey(scope, albumId)}:$assetId';

// Holds only the displayed album row while its captured cover flies. It does
// not change the persisted album/media list or manufacture a success receipt.
final albumDeletionHoldsProvider = StateProvider<Set<String>>((ref) => const {});

final ghostTrapProvider = Provider<GhostTrapCoordinator>((ref) {
  final coordinator = GhostTrapCoordinator();
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

/// Owns only transient pixels and geometry. It cannot delete, restore, decode
/// originals, issue network requests or grant a Live Photo playback lease.
class GhostTrapCoordinator extends ChangeNotifier with WidgetsBindingObserver {
  GhostTrapCoordinator() {
    WidgetsBinding.instance.addObserver(this);
  }

  final _sources = <_GhostSourceState>{};
  final _targets = <_GhostTrashTargetState>{};
  GhostFlight? _flight;
  bool _active = true;
  int _preparation = 0;
  bool _disposing = false;

  Future<GhostFlight?> prepare(
    BuildContext context,
    Iterable<String> assetKeys,
    GhostTrashKind kind, {
    String? targetKey,
  }) async {
    final preparation = ++_preparation;
    _flight?.cancel();
    if (!_active || !context.mounted) {
      return null;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      return null;
    }
    final target = _targets
        .where(
          (t) =>
              t.widget.kind == kind &&
              (targetKey == null || t.widget.targetKey == targetKey) &&
              t.route == route &&
              t.visibleRect != null,
        )
        .firstOrNull;
    if (target == null) {
      return null;
    } // Never fly into a fabricated/offscreen bin.
    final keys = assetKeys.toSet();
    final source = _sources
        .where((s) => keys.contains(s.widget.assetKey) && s.route == route && s.visibleRect != null)
        .firstOrNull;
    final boundary = source?._capture.currentContext?.findRenderObject();
    if (source == null || boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
      return null;
    }
    if (source.widget.requireImage && !_hasDecodedImage(boundary)) {
      return null;
    }
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      return null;
    }
    final sourceRect = source.visibleRect!;
    final positions = <Object, Rect>{
      for (final s in _sources)
        if (s.route == route) (s.route, s.widget.assetKey): ?_visibleRect(s._capture.currentContext),
    };
    final scroll = Scrollable.maybeOf(source.context)?.position;
    final scrollOffset = scroll?.pixels;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final color = Theme.of(context).colorScheme.primary;
    ui.Image image;
    try {
      final ratio = math.min(1.0, 512 / boundary.size.longestSide);
      final captured = await boundary.toImage(pixelRatio: ratio);
      if (source.widget.captureInsets == EdgeInsets.zero) {
        image = captured;
      } else {
        final inset = source.widget.captureInsets;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final crop = Rect.fromLTWH(
          inset.left * ratio,
          inset.top * ratio,
          sourceRect.width * ratio,
          sourceRect.height * ratio,
        );
        canvas.drawImageRect(captured, crop, Offset.zero & crop.size, Paint());
        final picture = recorder.endRecording();
        try {
          image = await picture.toImage(math.max(1, crop.width.round()), math.max(1, crop.height.round()));
        } finally {
          picture.dispose();
          captured.dispose();
        }
      }
    } catch (_) {
      return null; // Capture failure never prevents the underlying safe operation.
    }
    if (preparation != _preparation ||
        !_active ||
        !context.mounted ||
        route?.isCurrent == false ||
        target.visibleRect == null ||
        scroll?.pixels != scrollOffset) {
      image.dispose();
      return null;
    }
    final flight = GhostFlight._(
      this,
      image,
      sourceRect,
      source.widget.assetKey,
      positions,
      target,
      route,
      scroll,
      reduced,
      color,
      overlay,
    );
    _flight = flight;
    flight._show();
    notifyListeners();
    return flight;
  }

  void _repaint() => notifyListeners();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) {
      _flight?.cancel();
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _preparation++;
    _flight?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Created before the mutation. Pending pixels stay still; only a verified
/// OS/server receipt may call confirmed(). Errors/cancellation call cancel().
class GhostFlight implements TickerProvider {
  GhostFlight._(
    this._owner,
    this._image,
    this.sourceRect,
    this.assetKey,
    this._positions,
    this._target,
    this._route,
    this._scroll,
    this.reducedMotion,
    this._glow,
    this._overlay,
  ) : _scrollOffset = _scroll?.pixels {
    _controller = AnimationController(
      vsync: this,
      duration: _target.widget.kind == GhostTrashKind.album
          ? reducedMotion
                ? ghostTrapReducedDuration - ghostTrapAlbumReducedReflowDuration
                : ghostTrapDuration - ghostTrapAlbumReflowDuration
          : reducedMotion
          ? ghostTrapReducedDuration
          : ghostTrapDuration,
    )..addListener(_tick);
  }

  final GhostTrapCoordinator _owner;
  final ui.Image _image;
  final Rect sourceRect;
  final String assetKey;
  final Map<Object, Rect> _positions;
  final _GhostTrashTargetState _target;
  final ModalRoute<dynamic>? _route;
  final ScrollPosition? _scroll;
  final double? _scrollOffset;
  final bool reducedMotion;
  final Color _glow;
  final OverlayState _overlay;
  late final AnimationController _controller;
  OverlayEntry? _entry;
  bool _disposed = false;
  bool _confirmed = false;

  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);

  double get _reflow => !_confirmed
      ? 0
      : reducedMotion
      ? Curves.easeOut.transform(_controller.value)
      : Curves.easeOutCubic.transform(((_controller.value * 640 - 520) / 120).clamp(0, 1));

  bool get _valid =>
      !_disposed &&
      _owner._active &&
      _route?.isCurrent != false &&
      _target.visibleRect != null &&
      _scroll?.pixels == _scrollOffset;

  void _show() {
    _scroll?.addListener(_onScroll);
    _entry = OverlayEntry(
      builder: (context) {
        final overlayBox = _overlay.context.findRenderObject() as RenderBox?;
        final origin = overlayBox?.localToGlobal(Offset.zero) ?? Offset.zero;
        final target = _target.visibleRect;
        if (target == null) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey('ghost-trap-flight'),
                  painter: GhostTrapPainter(
                    image: _image,
                    source: sourceRect.shift(-origin),
                    target: target.center - origin,
                    progress: _controller.value,
                    confirmed: _confirmed,
                    reducedMotion: reducedMotion,
                    glow: _glow,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    _overlay.insert(_entry!);
  }

  void _onScroll() {
    if (_scroll?.pixels != _scrollOffset) {
      cancel();
    }
  }

  void _tick() {
    if (!_valid) {
      cancel();
      return;
    }
    _entry?.markNeedsBuild();
    _owner._repaint(); // RenderObject repaint listeners, not Timeline setState.
  }

  Future<void> confirmed() async {
    if (!_valid || _confirmed) {
      if (!_valid) {
        cancel();
      }
      return;
    }
    _confirmed = true;
    try {
      await _controller.forward().orCancel;
    } on TickerCanceled {
      // A navigation, scroll, app pause or disposal aborts only the effect.
    } finally {
      cancel();
    }
  }

  void cancel() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _scroll?.removeListener(_onScroll);
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    _controller.dispose();
    if (identical(_owner._flight, this)) {
      _owner._flight = null;
      if (!_owner._disposing) {
        _owner._repaint();
      }
    }
    unawaited(WidgetsBinding.instance.endOfFrame.then((_) => _image.dispose()));
  }
}

/// One already-painted thumbnail is captured once, never decoded each frame.
/// The same child/native player survives the lightweight paint transform.
class GhostSource extends ConsumerStatefulWidget {
  const GhostSource({
    super.key,
    required this.assetKey,
    required this.child,
    this.captureInsets = EdgeInsets.zero,
    this.requireImage = true,
  });
  final String assetKey;
  final EdgeInsets captureInsets;
  final bool requireImage;
  final Widget child;
  @override
  ConsumerState<GhostSource> createState() => _GhostSourceState();
}

class _GhostSourceState extends ConsumerState<GhostSource> {
  final _capture = GlobalKey();
  late final _owner = ref.read(ghostTrapProvider);
  ModalRoute<dynamic>? get route => mounted ? ModalRoute.of(context) : null;
  Rect? get visibleRect {
    final rect = mounted ? _visibleRect(_capture.currentContext) : null;
    if (rect == null) {
      return null;
    }
    final crop = widget.captureInsets.deflateRect(rect);
    return crop.isEmpty ? null : crop;
  }

  @override
  void initState() {
    super.initState();
    _owner._sources.add(this);
  }

  @override
  void dispose() {
    _owner._sources.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _GhostReflow(
    owner: _owner,
    token: (route, widget.assetKey),
    child: RepaintBoundary(key: _capture, child: widget.child),
  );
}

class GhostTrashTarget extends ConsumerStatefulWidget {
  const GhostTrashTarget({super.key, required this.kind, required this.child, this.enabled = true, this.targetKey});
  final GhostTrashKind kind;
  final String? targetKey;
  final bool enabled;
  final Widget child;
  @override
  ConsumerState<GhostTrashTarget> createState() => _GhostTrashTargetState();
}

class _GhostTrashTargetState extends ConsumerState<GhostTrashTarget> {
  final _anchor = GlobalKey();
  late final _owner = ref.read(ghostTrapProvider);
  ModalRoute<dynamic>? get route => mounted ? ModalRoute.of(context) : null;
  Rect? get visibleRect => mounted && widget.enabled ? _visibleRect(_anchor.currentContext, requireHit: true) : null;
  @override
  void initState() {
    super.initState();
    _owner._targets.add(this);
  }

  @override
  void dispose() {
    _owner._targets.remove(this);
    final flight = _owner._flight;
    if (flight?._target == this) {
      scheduleMicrotask(() => flight?.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _owner,
    child: widget.child,
    builder: (_, child) {
      final flight = _owner._flight;
      final t = flight?._reflow ?? 0;
      final bounce = flight?._target == this && flight?._confirmed == true && flight?.reducedMotion == false
          ? math.sin(t * math.pi) * .13
          : 0.0;
      return SizedBox(
        key: _anchor,
        child: Transform.rotate(
          angle: math.sin(t * math.pi * 4) * bounce,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                if (bounce > 0)
                  BoxShadow(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: bounce * 2),
                    blurRadius: 12,
                    spreadRadius: bounce * 20,
                  ),
              ],
            ),
            child: Transform.scale(scale: 1 + bounce, child: child),
          ),
        ),
      );
    },
  );
}

bool _hasDecodedImage(RenderObject object) {
  if (object is RenderImage && object.image != null) {
    return true;
  }
  var found = false;
  object.visitChildren((child) => found = found || _hasDecodedImage(child));
  return found;
}

Rect? _visibleRect(BuildContext? context, {bool requireHit = false}) {
  if (context == null || !context.mounted) {
    return null;
  }
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) {
    return null;
  }
  RenderObject? ancestor = box;
  while (ancestor != null) {
    if (ancestor is RenderOpacity && ancestor.opacity == 0 ||
        ancestor is RenderAnimatedOpacity && ancestor.opacity.value == 0 ||
        ancestor is RenderOffstage && ancestor.offstage) {
      return null;
    }
    ancestor = ancestor.parent;
  }
  final rect = box.localToGlobal(Offset.zero) & box.size;
  if (requireHit) {
    final result = HitTestResult();
    GestureBinding.instance.hitTestInView(result, rect.center, View.of(context).viewId);
    if (!result.path.any((entry) => identical(entry.target, box))) {
      return null;
    }
  }
  final screen = Offset.zero & MediaQuery.sizeOf(context);
  return screen.contains(rect.center) && rect.overlaps(screen) ? rect : null;
}

class _GhostReflow extends SingleChildRenderObjectWidget {
  const _GhostReflow({required this.owner, required this.token, required super.child});
  final GhostTrapCoordinator owner;
  final Object token;
  @override
  _RenderGhostReflow createRenderObject(BuildContext context) => _RenderGhostReflow(owner, token);
  @override
  void updateRenderObject(BuildContext context, _RenderGhostReflow renderObject) => renderObject.token = token;
}

class _RenderGhostReflow extends RenderProxyBox {
  _RenderGhostReflow(this.coordinator, this.token);
  final GhostTrapCoordinator coordinator;
  Object token;
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    coordinator.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    coordinator.removeListener(markNeedsPaint);
    super.detach();
  }

  Offset get translation {
    final flight = coordinator._flight;
    final oldRect = flight?._positions[token];
    if (flight == null || oldRect == null || !attached) {
      return Offset.zero;
    }
    return (oldRect.topLeft - localToGlobal(Offset.zero)) * (1 - flight._reflow);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final flight = coordinator._flight;
    if (flight?._confirmed == true && token == (flight!._route, flight.assetKey)) {
      return; // The captured cover is now in flight; retain the child/player state.
    }
    context.paintChild(child!, offset + translation);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => result.addWithPaintOffset(
    offset: translation,
    position: position,
    hitTest: (result, position) => super.hitTestChildren(result, position: position),
  );
  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    super.applyPaintTransform(child, transform);
    final delta = translation;
    transform.translateByDouble(delta.dx, delta.dy, 0, 1);
  }
}

/// A captured thumbnail follows a curved energy trail into the real target.
/// One image draw per frame; no full-resolution decoding or image-strip distortion.
class GhostTrapPainter extends CustomPainter {
  GhostTrapPainter({
    required this.image,
    required this.source,
    required this.target,
    required this.progress,
    required this.confirmed,
    required this.reducedMotion,
    required this.glow,
  });
  final ui.Image image;
  final Rect source;
  final Offset target;
  final double progress;
  final bool confirmed;
  final bool reducedMotion;
  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    if (!confirmed) {
      canvas.drawImageRect(image, src, source, Paint());
      return;
    }
    if (reducedMotion) {
      final scale = 1 - .04 * progress;
      canvas.drawImageRect(
        image,
        src,
        Rect.fromCenter(center: source.center, width: source.width * scale, height: source.height * scale),
        Paint()..color = Colors.white.withValues(alpha: 1 - progress),
      );
      return;
    }
    final travel = Curves.easeInOutCubic.transform((progress / .82).clamp(0, 1));
    if (travel >= 1) {
      return;
    }
    final start = source.center;
    final bend = Offset.lerp(start, target, .5)! - Offset(0, math.min(100, source.height * .35));
    final center =
        start * ((1 - travel) * (1 - travel)) + bend * (2 * travel * (1 - travel)) + target * (travel * travel);
    final trail = Path()
      ..moveTo(start.dx, start.dy)
      ..quadraticBezierTo(bend.dx, bend.dy, center.dx, center.dy);
    canvas.drawPath(
      trail,
      Paint()
        ..color = glow.withValues(alpha: math.sin(travel * math.pi) * .35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 + 4 * (1 - travel)
        ..strokeCap = StrokeCap.round,
    );
    final scale = 1 - .94 * travel;
    final rect = Rect.fromCenter(center: Offset.zero, width: source.width * scale, height: source.height * scale);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(math.sin(travel * math.pi) * .12);
    final outline = RRect.fromRectAndRadius(rect, const Radius.circular(10));
    canvas.clipRRect(outline);
    canvas.drawImageRect(
      image,
      src,
      rect,
      Paint()
        ..filterQuality = FilterQuality.low
        ..color = Colors.white.withValues(alpha: 1 - travel * travel),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(GhostTrapPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.confirmed != confirmed || oldDelegate.target != target;
}
