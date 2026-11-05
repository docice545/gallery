import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';

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
  var observing = false;
  late final GhostTrapCoordinator coordinator;
  coordinator = GhostTrapCoordinator(
    observePreference: () {
      if (observing) {
        return;
      }
      observing = true;
      // Thumbnails may mount before settings are needed. Subscribe lazily on
      // the first deletion, then retain this coordinator across live changes.
      ref.listen(
        fancyDeletionEnabledProvider,
        (_, enabled) => coordinator.setEffectsEnabled(enabled),
        fireImmediately: true,
      );
    },
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

/// Owns only transient pixels and geometry. It cannot delete, restore, decode
/// originals, issue network requests or grant a Live Photo playback lease.
class GhostTrapCoordinator extends ChangeNotifier with WidgetsBindingObserver {
  GhostTrapCoordinator({this.observePreference}) {
    WidgetsBinding.instance.addObserver(this);
  }

  final _sources = <_GhostSourceState>{};
  final _targets = <_GhostTrashTargetState>{};
  GhostFlight? _flight;
  bool _active = true;
  int _preparation = 0;
  bool _disposing = false;
  final VoidCallback? observePreference;
  bool _effectsEnabled = true;

  void setEffectsEnabled(bool enabled) {
    if (_effectsEnabled == enabled) {
      return;
    }
    _effectsEnabled = enabled;
    _preparation++;
    if (!enabled) {
      _flight?.cancel();
    }
  }

  Future<GhostFlight?> prepare(
    BuildContext context,
    Iterable<String> assetKeys,
    GhostTrashKind kind, {
    String? targetKey,
    VoidCallback? onIntake,
  }) async {
    observePreference?.call();
    final preparation = ++_preparation;
    _flight?.cancel();
    if (!_effectsEnabled || !_active || !context.mounted) {
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
    target._resolveIcon();
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
        !_effectsEnabled ||
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
      onIntake,
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
    this._onIntake,
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
  final VoidCallback? _onIntake;
  late final AnimationController _controller;
  OverlayEntry? _entry;
  bool _disposed = false;
  bool _confirmed = false;
  bool _intakeSignaled = false;

  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);

  double get _reflow => !_confirmed
      ? 0
      : reducedMotion
      ? Curves.easeOut.transform(_controller.value)
      : Curves.easeOutCubic.transform(((_controller.value * 640 - 520) / 120).clamp(0, 1));

  bool get _valid =>
      !_disposed &&
      _owner._effectsEnabled &&
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
                    target: _target.iconRect.center - origin,
                    binSize: _target.iconRect.shortestSide,
                    binColor: _target.iconColor,
                    binSurface: Theme.of(_target.context).colorScheme.surfaceContainerHigh,
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
    if (_confirmed && !_intakeSignaled && _controller.value >= .8) {
      _intakeSignaled = true;
      _onIntake?.call();
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

  Element? _icon;
  void _resolveIcon() {
    Element? found;
    void visit(Element element) {
      if (found != null) {
        return;
      }
      if (element.widget is FotoIcon || element.widget is Icon) {
        found = element;
      } else {
        element.visitChildren(visit);
      }
    }

    _anchor.currentContext?.visitChildElements(visit);
    _icon = found;
  }

  Rect get iconRect {
    final box = _icon?.mounted == true ? _icon?.findRenderObject() : null;
    if (box is RenderBox && box.attached && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    return Rect.fromCenter(center: visibleRect!.center, width: 24, height: 24);
  }

  Color get iconColor {
    final element = _icon?.mounted == true ? _icon : null;
    final colors = Theme.of(context).colorScheme;
    final icon = element?.widget;
    if (icon is FotoIcon) {
      return switch (icon.state) {
        FotoIconState.normal => colors.onSurface,
        FotoIconState.active => colors.primary,
        FotoIconState.disabled => colors.onSurface.withValues(alpha: .38),
        FotoIconState.destructive => colors.error,
      };
    }
    return (icon is Icon ? icon.color : null) ?? IconTheme.of(element ?? context).color ?? colors.onSurface;
  }

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
  Widget build(BuildContext context) => SizedBox(
    key: _anchor,
    child: _GhostTargetMask(target: this, owner: _owner, child: widget.child),
  );
}

/// Replace only the icon's paint while the overlay animates it. Button labels,
/// hit regions, semantics and layout stay intact; reduced motion uses the icon.
class _GhostTargetMask extends SingleChildRenderObjectWidget {
  const _GhostTargetMask({required this.target, required this.owner, required super.child});
  final _GhostTrashTargetState target;
  final GhostTrapCoordinator owner;
  @override
  _RenderGhostTargetMask createRenderObject(BuildContext context) => _RenderGhostTargetMask(target, owner);
}

class _RenderGhostTargetMask extends RenderProxyBox {
  _RenderGhostTargetMask(this.target, this.coordinator);
  final _GhostTrashTargetState target;
  final GhostTrapCoordinator coordinator;

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

  @override
  void paint(PaintingContext context, Offset offset) {
    final flight = coordinator._flight;
    if (flight?._target != target || flight?._confirmed != true || flight!.reducedMotion) {
      super.paint(context, offset);
      return;
    }
    final icon = target.iconRect.shift(-localToGlobal(Offset.zero)).inflate(1);
    final path = Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRect(icon));
    context.pushClipPath(needsCompositing, offset, Offset.zero & size, path, super.paint);
  }
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
  return rect.overlaps(screen) && (!requireHit || screen.contains(rect.center)) ? rect : null;
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
    coordinator.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    coordinator.removeListener(markNeedsLayout);
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
  void performLayout() {
    super.performLayout();
    final flight = coordinator._flight;
    final oldRect = flight?._positions[token];
    if (oldRect != null && child != null) {
      // Keep the original cover crop until intake finishes. Only the existing
      // render child is laid out; scaling its paint would distort the image.
      child!.layout(BoxConstraints.tight(Size.lerp(oldRect.size, child!.size, flight!._reflow)!), parentUsesSize: true);
    }
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

/// One captured image, one continuous mesh with 16 segments. The front wall is opaque:
/// disappearance is caused by the photo entering the opening, not by a fade.
/// All phases (including 2.5 damped rocking cycles) share the same 640ms clock.
class GhostTrapPainter extends CustomPainter {
  GhostTrapPainter({
    required this.image,
    required this.source,
    required this.target,
    required this.progress,
    required this.confirmed,
    required this.reducedMotion,
    required this.glow,
    this.binSize = 24,
    this.binColor = Colors.black,
    this.binSurface = Colors.white,
  });
  final ui.Image image;
  final Rect source;
  final Offset target;
  final double progress;
  final bool confirmed;
  final bool reducedMotion;
  final Color glow;
  final double binSize;
  final Color binColor;
  final Color binSurface;

  double _phase(double start, double end) => ((progress - start) / (end - start)).clamp(0, 1);
  double _ease(double start, double end) => Curves.easeInOutCubic.transform(_phase(start, end));

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
    final scale = binSize / 24 * (1 + .36 * _ease(.18, .45) * (1 - _ease(.9, 1)));
    final swallow = math.sin(math.pi * _phase(.68, .86));
    final shake = _phase(.8, .98);
    final angle = .14 * math.sin(shake * math.pi * 5) * math.pow(1 - shake, 2);
    final lid = _ease(.18, .48) * (1 - _ease(.77, .87));
    void binCoordinates(void Function() paint) {
      canvas.save();
      canvas.translate(target.dx, target.dy);
      canvas.rotate(angle);
      canvas.scale(scale * (1 + .08 * swallow), scale * (1 - .055 * swallow));
      canvas.translate(-12, -12);
      paint();
      canvas.restore();
    }

    final stroke = Paint()
      ..color = binColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.85
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // Rear rim and dark cavity precede the photograph in paint order.
    binCoordinates(() {
      canvas.drawOval(
        const Rect.fromLTWH(6.3, 5.9, 11.4, 3.4),
        Paint()..color = Color.alphaBlend(binColor.withValues(alpha: .32), binSurface),
      );
      canvas.drawArc(const Rect.fromLTWH(6.3, 5.9, 11.4, 3.4), math.pi, math.pi, false, stroke);
    });

    if (progress < .8) {
      final flight = Curves.easeInOutCubic.transform(_phase(0, .60));
      final intake = _ease(.60, .80);
      final mouthApproach = target + Offset(0, -19 * scale);
      final control1 = source.center + Offset((target.dx - source.center.dx) * .12, -source.height * .22);
      final control2 = mouthApproach + Offset((source.center.dx - target.dx) * .22, -64);
      final u = 1 - flight;
      var center =
          source.center * (u * u * u) +
          control1 * (3 * u * u * flight) +
          control2 * (3 * u * flight * flight) +
          mouthApproach * (flight * flight * flight);
      center = Offset.lerp(center, target + Offset(0, 3.5 * scale), intake)!;
      final width = ui.lerpDouble(ui.lerpDouble(source.width, 10 * scale, flight), 6 * scale, intake)!;
      final height = ui.lerpDouble(ui.lerpDouble(source.height, 24 * scale, flight), 6 * scale, intake)!;
      final curl = math.sin(math.pi * flight) * .65;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(.14 * math.sin(math.pi * flight));
      final rect = Rect.fromCenter(center: Offset.zero, width: width, height: height);
      if (flight > 0 && flight < .85) {
        canvas.drawShadow(
          Path()..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6))),
          glow.withValues(alpha: .18),
          3,
          false,
        );
      }
      // Shared mesh edges avoid antialiased seams between separate image strips.
      final positions = <Offset>[];
      final texture = <Offset>[];
      final indices = <int>[];
      for (var row = 0; row <= 16; row++) {
        final y = row / 16;
        final taper = 1 - curl * .35 * y;
        final shift = math.sin(y * math.pi * 1.5) * width * .12 * curl;
        positions.addAll([
          Offset(-width * taper / 2 + shift, -height / 2 + height * y),
          Offset(width * taper / 2 + shift, -height / 2 + height * y),
        ]);
        texture.addAll([Offset(0, image.height * y), Offset(image.width.toDouble(), image.height * y)]);
        if (row < 16) {
          final i = row * 2;
          indices.addAll([i, i + 1, i + 2, i + 1, i + 3, i + 2]);
        }
      }
      final vertices = ui.Vertices(ui.VertexMode.triangles, positions, textureCoordinates: texture, indices: indices);
      final shader = ui.ImageShader(image, TileMode.clamp, TileMode.clamp, Matrix4.identity().storage);
      canvas.drawVertices(
        vertices,
        BlendMode.srcOver,
        Paint()
          ..shader = shader
          ..filterQuality = FilterQuality.low,
      );
      vertices.dispose();
      shader.dispose();
      canvas.restore();
    }

    binCoordinates(() {
      // This wall physically hides the lower part of the swallowed photograph.
      final wall = Path()
        ..moveTo(6.5, 8.2)
        ..lineTo(7.2, 19)
        ..quadraticBezierTo(7.4, 20.5, 9.2, 20.5)
        ..lineTo(14.8, 20.5)
        ..quadraticBezierTo(16.6, 20.5, 16.8, 19)
        ..lineTo(17.5, 8.2)
        ..close();
      canvas.drawPath(wall, Paint()..color = binSurface.withValues(alpha: 1));
      final outline = Path()
        ..moveTo(6.5, 9)
        ..lineTo(7.2, 19)
        ..quadraticBezierTo(7.4, 20.5, 9.2, 20.5)
        ..lineTo(14.8, 20.5)
        ..quadraticBezierTo(16.6, 20.5, 16.8, 19)
        ..lineTo(17.5, 9);
      canvas.drawPath(outline, stroke);
      canvas.drawLine(const Offset(10, 11), const Offset(10, 17), stroke);
      canvas.drawLine(const Offset(14, 11), const Offset(14, 17), stroke);
      // A real hinge: the lid rotates around its left edge, then settles shut.
      canvas.save();
      canvas.translate(4, 7);
      canvas.rotate(-.95 * lid);
      canvas.translate(-4, -7);
      canvas.drawLine(const Offset(4, 7), const Offset(20, 7), stroke);
      canvas.drawPath(
        Path()
          ..moveTo(9, 7)
          ..lineTo(9, 4.5)
          ..lineTo(15, 4.5)
          ..lineTo(15, 7),
        stroke,
      );
      canvas.restore();
    });
  }

  @override
  bool shouldRepaint(GhostTrapPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.confirmed != confirmed ||
      oldDelegate.target != target ||
      oldDelegate.binColor != binColor ||
      oldDelegate.binSurface != binSurface ||
      oldDelegate.binSize != binSize;
}
