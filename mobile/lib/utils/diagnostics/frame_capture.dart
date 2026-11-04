import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Opt-in profile tooling. No callback or service extension exists in release,
/// or in ordinary profile runs. Captures timings only, never assets or tokens.
void installFotoFrameCapture() {
  if (!kProfileMode || !const bool.fromEnvironment('FOTO_FRAME_CAPTURE')) {
    return;
  }
  FrameCapture? active;
  var stopping = false;
  int? end;
  var start = 0;
  void record(List<FrameTiming> timings) {
    final capture = active;
    if (capture == null) {
      return;
    }
    for (final timing in timings) {
      final built = timing.timestampInMicroseconds(FramePhase.buildStart);
      if (built >= start && (end == null || built <= end!)) {
        capture.add(timing.buildDuration.inMicroseconds, timing.rasterDuration.inMicroseconds);
      }
    }
  }

  developer.registerExtension('ext.foto.frames', (method, parameters) async {
    try {
      if (parameters['action'] == 'start') {
        if (active != null) {
          throw StateError('A capture is already active');
        }
        final hz = double.parse(parameters['hz'] ?? '120');
        if (!hz.isFinite || hz < 24 || hz > 240) {
          throw ArgumentError('Expected display Hz between 24 and 240');
        }
        active = FrameCapture(hz: hz);
        end = null;
        start = developer.Timeline.now;
        SchedulerBinding.instance.addTimingsCallback(record);
        return developer.ServiceExtensionResponse.result(jsonEncode({'started': true}));
      }
      if (parameters['action'] == 'stop' && active != null && !stopping) {
        stopping = true;
        end = developer.Timeline.now;
        // Engine timing delivery is batched. Drain the final batch once; frames
        // built after the stop timestamp are excluded. No periodic timer.
        await Future<void>.delayed(const Duration(seconds: 1));
        SchedulerBinding.instance.removeTimingsCallback(record);
        final result = active!.report();
        final views = PlatformDispatcher.instance.views;
        final view = views.isEmpty ? null : views.first;
        result['sourceSha'] = const String.fromEnvironment('FOTO_PROFILE_SOURCE_SHA');
        result['reportedDisplayHz'] = view?.display.refreshRate;
        result['devicePixelRatio'] = view?.devicePixelRatio;
        result['logicalWidth'] = view == null ? null : view.physicalSize.width / view.devicePixelRatio;
        result['logicalHeight'] = view == null ? null : view.physicalSize.height / view.devicePixelRatio;
        active = null;
        stopping = false;
        return developer.ServiceExtensionResponse.result(jsonEncode(result));
      }
      throw StateError('Expected start or stop for the current capture');
    } catch (error) {
      return developer.ServiceExtensionResponse.error(developer.ServiceExtensionResponse.extensionError, '$error');
    }
  });
}

class FrameCapture {
  FrameCapture({required this.hz, this.limit = 40000});
  final double hz;
  final int limit;
  final _ui = <int>[];
  final _raster = <int>[];
  var dropped = 0;

  void add(int uiMicroseconds, int rasterMicroseconds) {
    if (_ui.length >= limit) {
      dropped++;
      return;
    }
    _ui.add(uiMicroseconds);
    _raster.add(rasterMicroseconds);
  }

  Map<String, Object?> report() {
    final budget = 1000000 / hz;
    Map<String, Object?> stats(List<int> values) {
      final ordered = List.of(values)..sort();
      double? percentile(double p) =>
          ordered.isEmpty ? null : ordered[math.max(0, (ordered.length * p).ceil() - 1)] / 1000;
      return {
        'p50Ms': percentile(.5),
        'p95Ms': percentile(.95),
        'p99Ms': percentile(.99),
        'overBudget': values.where((v) => v > budget).length,
      };
    }

    final jank = List.generate(_ui.length, (i) => _ui[i] > budget || _raster[i] > budget).where((v) => v).length;
    return {
      'schema': 1,
      'mode': 'profile',
      'requestedHz': hz,
      'budgetMs': budget / 1000,
      'frames': _ui.length,
      'droppedSamples': dropped,
      'ui': stats(_ui),
      'raster': stats(_raster),
      'jankFrames': jank,
      'jankPercent': _ui.isEmpty ? null : jank * 100 / _ui.length,
      'uiMicroseconds': _ui,
      'rasterMicroseconds': _raster,
      'acceptance': 'REVIEW_REQUIRED',
    };
  }
}
