#!/usr/bin/env bash
# Source-level regression gate. A mock native position is not Samsung acceptance.
set -euo pipefail
cd "$(dirname "$0")/.."
exec flutter test --no-pub --concurrency=1 \
  test/presentation/widgets/timeline/live_photo_autoplay_test.dart \
  test/presentation/widgets/timeline/live_photo_scope_test.dart \
  test/presentation/widgets/timeline/live_photo_presentation_test.dart \
  test/presentation/widgets/images/thumbnail_live_photo_test.dart \
  test/presentation/widgets/asset_viewer/timeline_preview_video_viewer_test.dart
