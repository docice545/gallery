import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/diagnostics/frame_capture.dart';

void main() {
  test('UI/raster percentiles and jank union use the 120Hz budget, not summed durations', () {
    final capture = FrameCapture(hz: 120);
    for (var i = 1; i <= 100; i++) {
      capture.add(i * 100, (101 - i) * 100);
    }
    final report = capture.report();
    expect(report['frames'], 100);
    expect(report['budgetMs'], closeTo(8.333333, .000001));
    expect(report['ui'], {'p50Ms': 5.0, 'p95Ms': 9.5, 'p99Ms': 9.9, 'overBudget': 17});
    expect(report['raster'], report['ui']);
    expect(report['jankFrames'], 34);
    expect(report['jankPercent'], 34.0);
    expect(report['acceptance'], 'REVIEW_REQUIRED');
  });
  test('empty samples are not zero-latency evidence and truncation is explicit', () {
    final capture = FrameCapture(hz: 120, limit: 1);
    expect((capture.report()['ui']! as Map)['p95Ms'], isNull);
    expect(capture.report()['jankPercent'], isNull);
    capture.add(8000, 8000);
    capture.add(9000, 9000);
    expect(capture.report()['frames'], 1);
    expect(capture.report()['droppedSamples'], 1);
    expect(capture.report()['jankFrames'], 0);
  });
}
