import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/magic_eraser.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/edit/magic_eraser_availability.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/editor_chrome.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/editor_dock.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/repositories/magic_eraser.repository.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';

/// The canvas is always the server's oriented original, independent of local
/// availability and of the nondestructive crop editor's current transform.
class MagicEraserPage extends ConsumerStatefulWidget {
  final RemoteAsset asset;

  const MagicEraserPage({super.key, required this.asset});

  @override
  ConsumerState<MagicEraserPage> createState() => _MagicEraserPageState();
}

class _MagicEraserPageState extends ConsumerState<MagicEraserPage> {
  bool _brushOptions = false;
  late final MagicEraserRepository _repository;
  final _pageAbort = Completer<void>();
  final _transform = TransformationController();
  final _cancelledJobs = <String>{};
  Completer<void>? _operationAbort;
  Uint8List? _source;
  Uint8List? _result;
  Size? _sourceSize;
  MagicEraserMask _mask = MagicEraserMask();
  final _strokePoints = <Offset>[];
  final _imageKey = GlobalKey();
  Offset? _lastPhotoPoint;
  final _pointers = <int>{};
  int? _strokePointer;
  Size? _strokeSize;
  double _brushSize = 32;
  double _strokeRadius = 0.02;
  bool _drawing = false;
  bool _strokeErase = false;
  bool _erase = false;
  bool _zoom = false;
  bool _loading = true;
  bool _enabled = false;
  bool _processing = false;
  bool _saving = false;
  bool _before = false;
  bool _queued = false;
  bool _timeout = false;
  bool _failed = false;
  Object? _loadError;
  String? _jobId;
  int _generation = 0;

  bool get _busy => _loading || _processing || _saving;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(magicEraserRepositoryProvider);
    _transform.addListener(_discardStroke);
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
      _loadError = null;
    });
    try {
      final enabled = await _repository.isEnabled(widget.asset.id, abortTrigger: _pageAbort.future);
      if (!enabled || !mounted) {
        if (mounted) {
          setState(() {
            _enabled = false;
            _loading = false;
          });
        }
        return;
      }
      final source = await _repository.source(widget.asset.id, abortTrigger: _pageAbort.future);
      final size = await _previewSize(source);
      if (!mounted) {
        return;
      }
      setState(() {
        _enabled = true;
        _loading = false;
        _source = source;
        _sourceSize = size;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
          _loadError = error;
        });
      }
    }
  }

  Future<Size> _previewSize(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 || descriptor.height <= 0 || descriptor.width > 1600 || descriptor.height > 1600) {
        throw const FormatException('Invalid magic eraser preview dimensions');
      }
      return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<void> _cancelRemote(String id) async {
    if (!_cancelledJobs.add(id)) {
      return;
    }
    try {
      await _repository.cancel(widget.asset.id, id);
    } catch (_) {
      // The bounded server job expiry also removes disconnected previews.
    }
  }

  void _cancel() {
    _generation++;
    final abort = _operationAbort;
    if (abort != null && !abort.isCompleted) {
      abort.complete();
    }
    final jobId = _jobId;
    _jobId = null;
    if (jobId != null) {
      unawaited(_cancelRemote(jobId));
    }
    setState(() => _processing = false);
  }

  void _changeMask(MagicEraserMask mask) {
    final result = _result;
    if (result != null) {
      unawaited(MemoryImage(result).evict());
    }
    final jobId = _jobId;
    _jobId = null;
    if (jobId != null) {
      unawaited(_cancelRemote(jobId));
    }
    setState(() {
      _mask = mask;
      _result = null;
      _before = false;
      _failed = false;
      _timeout = false;
    });
  }

  bool _current(int generation) => mounted && generation == _generation;

  Future<void> _remove() async {
    if (_busy || _drawing || !_mask.hasSelection) {
      return;
    }
    final generation = ++_generation;
    final abort = _operationAbort = Completer<void>();
    final previousJob = _jobId;
    _jobId = null;
    setState(() {
      _processing = true;
      _queued = true;
      _failed = false;
      _timeout = false;
    });
    try {
      if (previousJob != null) {
        await _cancelRemote(previousJob);
      }
      if (!_current(generation)) {
        return;
      }
      // Do not abort creation: if Cancel races the response, obtain its id and
      // explicitly discard the server job instead of abandoning an unknown id.
      var job = await _repository.create(widget.asset.id, _mask.strokes);
      if (!_current(generation)) {
        await _cancelRemote(job.id);
        return;
      }
      _jobId = job.id;
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      while (_current(generation)) {
        if (job.status == MagicEraserStatus.ready) {
          final preview = await _repository.preview(widget.asset.id, job.id, abortTrigger: abort.future);
          await _previewSize(preview);
          if (_current(generation)) {
            setState(() {
              _result = preview;
              _before = false;
              _processing = false;
            });
          }
          return;
        }
        if (job.status == MagicEraserStatus.failed || job.status == MagicEraserStatus.cancelled) {
          throw StateError('Inpainting failed');
        }
        if (DateTime.now().isAfter(deadline)) {
          await _cancelRemote(job.id);
          if (_current(generation)) {
            setState(() => _timeout = true);
          }
          return;
        }
        setState(() => _queued = job.status == MagicEraserStatus.queued);
        await Future.any([Future<void>.delayed(const Duration(seconds: 1)), abort.future]);
        if (!_current(generation)) {
          return;
        }
        job = await _repository.getJob(widget.asset.id, job.id, abortTrigger: abort.future);
      }
    } catch (_) {
      if (_current(generation)) {
        final jobId = _jobId;
        _jobId = null;
        if (jobId != null) {
          unawaited(_cancelRemote(jobId));
        }
        setState(() => _failed = true);
      }
    } finally {
      if (!abort.isCompleted) {
        abort.complete();
      }
      if (_current(generation)) {
        setState(() => _processing = false);
      }
    }
  }

  Future<void> _saveCopy() async {
    final jobId = _jobId;
    if (_busy || _result == null || jobId == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      final savedAssetId = await _repository.save(widget.asset.id, jobId);
      // A successful save must not race dispose's cancellation request.
      _jobId = null;
      if (mounted) {
        ImmichToast.show(context: context, msg: context.t.success, toastType: ToastType.success);
        Navigator.of(context).pop(savedAssetId);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _failed = true;
        });
      }
    }
  }

  // Track pointers over the entire viewport, including the letterbox. Raw
  // events keep the brush independent of InteractiveViewer's gesture arena.
  void _pointerDown(PointerDownEvent event) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1) {
      _discardStroke();
      return;
    }
    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (_busy ||
        _zoom ||
        _result != null ||
        event.buttons != kPrimaryButton ||
        box == null ||
        !box.size.contains(box.globalToLocal(event.position))) {
      return;
    }
    _lastPhotoPoint = event.position;
    _strokePointer = event.pointer;
    _strokeSize = box.size;
    _startStroke(box.globalToLocal(event.position), box.size);
  }

  void _pointerMove(PointerMoveEvent event) {
    if (_strokePointer != event.pointer) {
      return;
    }
    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || box.size != _strokeSize) {
      _discardStroke();
      return;
    }
    _lastPhotoPoint = event.position;
    // globalToLocal already inverts the InteractiveViewer transform.
    _addPoint(box.globalToLocal(event.position), box.size);
  }

  void _pointerUp(PointerUpEvent event) {
    if (_strokePointer == event.pointer) {
      final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.size == _strokeSize) {
        _lastPhotoPoint = event.position;
        _addPoint(box.globalToLocal(event.position), box.size);
        _strokePointer = null;
        _finishStroke();
      } else {
        _discardStroke();
      }
    }
    _pointers.remove(event.pointer);
  }

  void _pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _discardStroke();
  }

  void _discardStroke() {
    _strokePointer = null;
    if (_drawing) {
      setState(() {
        _drawing = false;
        _strokePoints.clear();
      });
    }
  }

  void _startStroke(Offset point, Size size) {
    _drawing = false;
    _strokePoints.clear();
    if (_busy || _zoom || _mask.strokes.length >= MagicEraserMask.maxStrokes) {
      return;
    }
    _drawing = true;
    _strokeErase = _erase;
    _strokeRadius = (_brushSize / (2 * size.shortestSide)).clamp(0.001, 0.25);
    _addPoint(point, size);
  }

  void _addPoint(Offset point, Size size) {
    if (!_drawing ||
        _busy ||
        _zoom ||
        point.dx < 0 ||
        point.dy < 0 ||
        point.dx > size.width ||
        point.dy > size.height) {
      return;
    }
    if (_strokePoints.length >= MagicEraserStroke.maxPoints ||
        _mask.pointCount + _strokePoints.length >= MagicEraserMask.maxTotalPoints) {
      return;
    }
    final normalized = Offset(point.dx / size.width, point.dy / size.height);
    if (_strokePoints.isNotEmpty && (normalized - _strokePoints.last).distance < 0.002) {
      return;
    }
    setState(() => _strokePoints.add(normalized));
  }

  void _finishStroke() {
    _drawing = false;
    if (_busy) {
      _strokePoints.clear();
      return;
    }
    if (_strokePoints.isEmpty) {
      return;
    }
    final stroke = MagicEraserStroke(points: _strokePoints, radius: _strokeRadius, erase: _strokeErase);
    _strokePoints.clear();
    _changeMask(_mask.add(stroke));
  }

  @override
  void dispose() {
    _generation++;
    _pageAbort.complete();
    final abort = _operationAbort;
    if (abort != null && !abort.isCompleted) {
      abort.complete();
    }
    final jobId = _jobId;
    // Once import starts, it is an atomic server operation. Never cancel a copy
    // which may already have become a normal Gallery asset.
    if (jobId != null && !_saving) {
      unawaited(_cancelRemote(jobId));
    }
    if (_source != null) {
      unawaited(MemoryImage(_source!).evict());
    }
    if (_result != null) {
      unawaited(MemoryImage(_result!).evict());
    }
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EditorChrome(
      child: PopScope(
        canPop: !_saving,
        child: Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          appBar: AppBar(
            backgroundColor: Theme.of(context).colorScheme.surface,
            toolbarHeight: kToolbarHeight,
            systemOverlayStyle: editorSystemUiStyle(context),
            leading: IconButton(
              key: const Key('eraser-back'),
              tooltip: context.t.back,
              onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
              icon: FotoIcon(
                kind: FotoIconKind.back,
                semanticLabel: context.t.back,
                state: _saving ? FotoIconState.disabled : FotoIconState.normal,
              ),
            ),
            actions: [
              IconButton(
                key: const Key('eraser-header-undo'),
                tooltip: context.t.undo,
                onPressed: _busy || _drawing || !_mask.canUndo ? null : () => _changeMask(_mask.undo()),
                icon: FotoIcon(
                  kind: FotoIconKind.undo,
                  semanticLabel: context.t.undo,
                  state: _busy || _drawing || !_mask.canUndo ? FotoIconState.disabled : FotoIconState.normal,
                ),
              ),
              IconButton(
                key: const Key('eraser-header-redo'),
                tooltip: context.t.magic_eraser_redo,
                onPressed: _busy || _drawing || !_mask.canRedo ? null : () => _changeMask(_mask.redo()),
                icon: FotoIcon(
                  kind: FotoIconKind.redo,
                  semanticLabel: context.t.magic_eraser_redo,
                  state: _busy || _drawing || !_mask.canRedo ? FotoIconState.disabled : FotoIconState.normal,
                ),
              ),
              SizedBox.square(
                dimension: 48,
                child: Tooltip(
                  message: context.t.magic_eraser_save_copy,
                  child: FilledButton(
                    key: const Key('eraser-save'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.square(48),
                      padding: EdgeInsets.zero,
                      backgroundColor: Colors.transparent,
                      disabledBackgroundColor: Colors.transparent,
                    ),
                    onPressed: _busy || _drawing || _result == null ? null : _saveCopy,
                    child: FotoIcon(
                      kind: FotoIconKind.saveCopy,
                      semanticLabel: context.t.magic_eraser_save_copy,
                      state: _busy || _drawing || _result == null ? FotoIconState.disabled : FotoIconState.normal,
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final canvas = SizedBox.expand(key: const Key('eraser-canvas-region'), child: _canvas());
                return Column(
                  children: [
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          canvas,
                          if (_failed || _timeout)
                            Positioned(
                              top: 8,
                              left: 12,
                              right: 12,
                              child: IgnorePointer(
                                child: Material(
                                  color: Theme.of(context).colorScheme.errorContainer,
                                  borderRadius: BorderRadius.circular(12),
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Text(
                                      _timeout ? context.t.magic_eraser_timeout : context.t.magic_eraser_failed,
                                      key: const Key('eraser-failure-status'),
                                      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (constraints.maxHeight >= EditorDock.height + MediaQuery.paddingOf(context).bottom)
                      if (_source != null)
                        _controls()
                      else
                        SizedBox(height: EditorDock.height + MediaQuery.paddingOf(context).bottom),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _canvas() {
    if (_loading) {
      return Center(child: SingleChildScrollView(child: _loadingState(context.t.magic_eraser_loading)));
    }
    if (!_enabled || _source == null || _sourceSize == null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                magicEraserAvailabilityMessage(context, _loadError),
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              ),
              TextButton(onPressed: _load, child: Text(context.t.retry)),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = math.min(constraints.maxWidth / _sourceSize!.width, constraints.maxHeight / _sourceSize!.height);
        final size = _sourceSize! * scale;
        final displayed = _result != null && !_before ? _result! : _source!;
        final showMask = _result == null;
        return Stack(
          children: [
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _pointerDown,
              onPointerMove: _pointerMove,
              onPointerUp: _pointerUp,
              onPointerCancel: _pointerCancel,
              child: InteractiveViewer(
                transformationController: _transform,
                panEnabled: _zoom && !_busy,
                scaleEnabled: _zoom && !_busy,
                minScale: 1,
                maxScale: 6,
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: Center(
                    child: Semantics(
                      label: context.t.magic_eraser_brush,
                      child: SizedBox(
                        key: const Key('eraser-canvas'),
                        width: size.width,
                        height: size.height,
                        child: Stack(
                          key: _imageKey,
                          fit: StackFit.expand,
                          children: [
                            Image.memory(displayed, fit: BoxFit.fill, gaplessPlayback: true),
                            if (showMask)
                              IgnorePointer(
                                child: CustomPaint(
                                  painter: _MaskPainter(
                                    _mask.strokes,
                                    _strokePoints.isEmpty
                                        ? null
                                        : MagicEraserStroke(
                                            points: _strokePoints,
                                            radius: _strokeRadius,
                                            erase: _strokeErase,
                                          ),
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
            ),
            if (_processing || _saving)
              Positioned.fill(
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surface.withValues(alpha: .96),
                  child: Center(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _loadingState(
                            _saving
                                ? context.t.magic_eraser_save_copy
                                : _queued
                                ? context.t.magic_eraser_queued
                                : context.t.magic_eraser_processing,
                          ),
                          if (_processing)
                            TextButton(
                              key: const Key('eraser-cancel'),
                              onPressed: _cancel,
                              child: Text(context.t.cancel),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _loadingState(String text) => Column(
    mainAxisSize: MainAxisSize.min,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const CircularProgressIndicator(),
      const SizedBox(height: 12),
      Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
    ],
  );

  Widget _controls() => EditorDock(
    key: const Key('eraser-controls-panel'),
    avoidPoint: () => _lastPhotoPoint,
    onDismiss: () {
      if (_brushOptions) {
        setState(() => _brushOptions = false);
      }
    },
    popover: _brushOptions
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.t.magic_eraser_brush_size),
              Slider(
                key: const Key('eraser-brush-size'),
                min: 4,
                max: 96,
                value: _brushSize,
                onChanged: _busy || _drawing ? null : (size) => setState(() => _brushSize = size),
                onChangeEnd: (_) => setState(() => _brushOptions = false),
              ),
            ],
          )
        : null,
    controls: [
      FotoIconButton(
        key: const Key('eraser-brush'),
        kind: FotoIconKind.brush,
        label: context.t.magic_eraser_brush,
        selected: !_erase && !_zoom,
        onPressed: _busy || _drawing
            ? null
            : () => setState(() {
                _erase = false;
                _zoom = false;
              }),
      ),
      FotoIconButton(
        key: const Key('eraser-erase-mask'),
        kind: FotoIconKind.eraser,
        label: context.t.magic_eraser_erase_mask,
        selected: _erase && !_zoom,
        onPressed: _busy || _drawing
            ? null
            : () => setState(() {
                _erase = true;
                _zoom = false;
              }),
      ),
      FotoIconButton(
        key: const Key('eraser-zoom'),
        kind: FotoIconKind.zoom,
        label: context.t.magic_eraser_zoom,
        selected: _zoom,
        onPressed: _busy || _drawing ? null : () => setState(() => _zoom = !_zoom),
      ),
      FotoIconButton(
        key: const Key('eraser-size-options'),
        kind: FotoIconKind.adjustments,
        label: context.t.magic_eraser_brush_size,
        selected: _brushOptions,
        onPressed: _busy || _drawing ? null : () => setState(() => _brushOptions = !_brushOptions),
      ),
      FotoIconButton(
        key: const Key('eraser-reset'),
        kind: FotoIconKind.reset,
        label: context.t.reset,
        onPressed: _busy || _drawing ? null : () => _changeMask(_mask.reset()),
      ),
      SizedBox.square(
        dimension: 48,
        child: Tooltip(
          message: context.t.remove,
          child: FilledButton(
            key: const Key('eraser-remove'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.square(48),
              padding: EdgeInsets.zero,
              backgroundColor: Colors.transparent,
              disabledBackgroundColor: Colors.transparent,
            ),
            onPressed: _busy || _drawing || !_mask.hasSelection || _result != null ? null : _remove,
            child: FotoIcon(
              kind: FotoIconKind.magicEraser,
              semanticLabel: context.t.remove,
              state: _busy || _drawing || !_mask.hasSelection || _result != null
                  ? FotoIconState.disabled
                  : FotoIconState.normal,
            ),
          ),
        ),
      ),
      if (_result != null) ...[
        FotoIconButton(
          key: const Key('eraser-before'),
          kind: FotoIconKind.cover,
          label: context.t.magic_eraser_before,
          selected: _before,
          onPressed: _busy || _drawing ? null : () => setState(() => _before = true),
        ),
        FotoIconButton(
          key: const Key('eraser-after'),
          kind: FotoIconKind.edit,
          label: context.t.magic_eraser_after,
          selected: !_before,
          onPressed: _busy || _drawing ? null : () => setState(() => _before = false),
        ),
      ],
    ],
  );
}

class _MaskPainter extends CustomPainter {
  final List<MagicEraserStroke> strokes;
  final MagicEraserStroke? active;

  const _MaskPainter(this.strokes, this.active);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final stroke in [...strokes, ?active]) {
      final radius = stroke.radius * size.shortestSide;
      final paint = Paint()
        ..color = Colors.purpleAccent.withValues(alpha: 0.55)
        ..blendMode = stroke.erase ? BlendMode.clear : BlendMode.src
        ..strokeWidth = radius * 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final points = [for (final point in stroke.points) Offset(point.dx * size.width, point.dy * size.height)];
      if (points.length == 1) {
        paint.style = PaintingStyle.fill;
        canvas.drawCircle(points.single, radius, paint);
      } else {
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final point in points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MaskPainter oldDelegate) =>
      oldDelegate.strokes != strokes || oldDelegate.active != active;
}
