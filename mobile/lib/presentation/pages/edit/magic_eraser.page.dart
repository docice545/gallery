import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/magic_eraser.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
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
  String? _jobId;
  int _generation = 0;

  bool get _busy => _loading || _processing || _saving;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(magicEraserRepositoryProvider);
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
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
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
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
      await _repository.save(widget.asset.id, jobId);
      // A successful save must not race dispose's cancellation request.
      _jobId = null;
      if (mounted) {
        ImmichToast.show(context: context, msg: context.t.success, toastType: ToastType.success);
        Navigator.of(context).pop(true);
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
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: Text(context.t.magic_eraser)),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  widget.asset.isMotionPhoto
                      ? context.t.magic_eraser_live_notice
                      : context.t.magic_eraser_original_notice,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              Expanded(child: _canvas()),
              if ((_failed || _timeout) && _source != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _timeout ? context.t.magic_eraser_timeout : context.t.magic_eraser_failed,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              if (_source != null) _controls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _canvas() {
    if (_loading) {
      return _loadingState(context.t.magic_eraser_loading);
    }
    if (!_enabled || _source == null || _sourceSize == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _failed ? context.t.magic_eraser_failed : context.t.magic_eraser_unavailable,
              style: const TextStyle(color: Colors.white),
            ),
            TextButton(onPressed: _load, child: Text(context.t.retry)),
          ],
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
            InteractiveViewer(
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
                    child: GestureDetector(
                      key: const Key('eraser-canvas'),
                      onPanStart: _busy || _zoom || !showMask
                          ? null
                          : (details) => _startStroke(details.localPosition, size),
                      onPanUpdate: _busy || _zoom || !showMask
                          ? null
                          : (details) => _addPoint(details.localPosition, size),
                      onPanEnd: _busy || _zoom || !showMask ? null : (_) => _finishStroke(),
                      onPanCancel: _busy || _zoom || !showMask ? null : _finishStroke,
                      onTapDown: _busy || _zoom || !showMask
                          ? null
                          : (details) => _startStroke(details.localPosition, size),
                      onTapUp: _busy || _zoom || !showMask ? null : (_) => _finishStroke(),
                      onTapCancel: _busy || _zoom || !showMask
                          ? null
                          : () => setState(() {
                              _drawing = false;
                              _strokePoints.clear();
                            }),
                      child: SizedBox(
                        width: size.width,
                        height: size.height,
                        child: Stack(
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
                  color: Colors.black54,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _loadingState(
                        _saving
                            ? context.t.magic_eraser_save_copy
                            : _queued
                            ? context.t.magic_eraser_queued
                            : context.t.magic_eraser_processing,
                      ),
                      if (_processing)
                        TextButton(key: const Key('eraser-cancel'), onPressed: _cancel, child: Text(context.t.cancel)),
                    ],
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
      Text(text, style: const TextStyle(color: Colors.white)),
    ],
  );

  Widget _controls() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_result != null)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              TextButton(
                onPressed: _busy || _drawing ? null : () => setState(() => _before = true),
                child: Text(context.t.magic_eraser_before),
              ),
              TextButton(
                onPressed: _busy || _drawing ? null : () => setState(() => _before = false),
                child: Text(context.t.magic_eraser_after),
              ),
              FilledButton(
                key: const Key('eraser-save'),
                onPressed: _busy || _drawing ? null : _saveCopy,
                child: Text(context.t.magic_eraser_save_copy),
              ),
            ],
          ),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            IconButton(
              tooltip: context.t.magic_eraser_brush,
              isSelected: !_erase && !_zoom,
              onPressed: _busy || _drawing
                  ? null
                  : () => setState(() {
                      _erase = false;
                      _zoom = false;
                    }),
              icon: const Icon(Icons.brush, color: Colors.white),
            ),
            IconButton(
              tooltip: context.t.magic_eraser_erase_mask,
              isSelected: _erase && !_zoom,
              onPressed: _busy || _drawing
                  ? null
                  : () => setState(() {
                      _erase = true;
                      _zoom = false;
                    }),
              icon: const Icon(Icons.auto_fix_off, color: Colors.white),
            ),
            IconButton(
              tooltip: context.t.magic_eraser_zoom,
              isSelected: _zoom,
              onPressed: _busy || _drawing ? null : () => setState(() => _zoom = !_zoom),
              icon: const Icon(Icons.zoom_in, color: Colors.white),
            ),
            IconButton(
              tooltip: context.t.undo,
              onPressed: _busy || _drawing || !_mask.canUndo ? null : () => _changeMask(_mask.undo()),
              icon: const Icon(Icons.undo, color: Colors.white),
            ),
            IconButton(
              tooltip: context.t.magic_eraser_redo,
              onPressed: _busy || _drawing || !_mask.canRedo ? null : () => _changeMask(_mask.redo()),
              icon: const Icon(Icons.redo, color: Colors.white),
            ),
            TextButton(
              onPressed: _busy || _drawing ? null : () => _changeMask(_mask.reset()),
              child: Text(context.t.reset),
            ),
          ],
        ),
        Column(
          children: [
            Text(context.t.magic_eraser_brush_size, style: const TextStyle(color: Colors.white)),
            Slider(
              key: const Key('eraser-brush-size'),
              min: 4,
              max: 96,
              value: _brushSize,
              onChanged: _busy || _drawing ? null : (size) => setState(() => _brushSize = size),
            ),
            FilledButton(
              key: const Key('eraser-remove'),
              onPressed: _busy || _drawing || !_mask.hasSelection || _result != null ? null : _remove,
              child: Text(context.t.remove),
            ),
          ],
        ),
      ],
    ),
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
