# Single horizontal photos

The singleton-day height limit applies to horizontal photos as well as portraits. Classic FOTO and the immersive Google Photos presentation use the chosen density target, capped at 280 logical pixels. Wider panoramas can be shorter. Images use the existing cover crop, never geometric stretching; the viewer and original bytes are unchanged.

Actual **6 PASS** on 2026-11-05, Flutter 3.47.2: 4:3, 16:9 and 4:1 horizontal inputs in both presentations, each changing density 2 → 4 → 6 in the real Timeline. Tests require bounded, non-increasing height, valid width and decoded photo-color pixels. Initial captures exposed the test harness taking screenshots before the resized asynchronous codec finished; captures now wait for decoding and assert color instead of accepting grey placeholders.

The three included synthetic renders were opened and reviewed after that correction. They show separate one-photo days; the immersive mode deliberately omits date headers. These are widget-rendered evidence, not Samsung screenshots.

```sh
cd mobile
flutter test --no-pub --dart-define=FOTO_MOSAIC_CAPTURE=true \
  --dart-define=FOTO_MOSAIC_ARTIFACT_DIR=/tmp/foto-horizontal \
  test/presentation/widgets/timeline/justified_timeline_widget_test.dart \
  --plain-name 'single horizontal' --reporter expanded
```

**DEVICE_REQUIRED:** real Samsung horizontal photos/panoramas, both modes and densities, screen rotation, zoom, selection, date and scroll-anchor retention.
