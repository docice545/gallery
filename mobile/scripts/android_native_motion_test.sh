#!/usr/bin/env bash
set -euo pipefail

# The hosted emulator shares memory with Gradle. Bound parallel workers and give
# Jetifier enough heap for MapLibre's native AAR; the previous 4 GiB heap failed
# before the integration test could install or exercise the real player.
# System properties affect this disposable test build only, not release builds.
export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.jvmargs=-Xmx6g -Dorg.gradle.workers.max=2 -Dorg.gradle.parallel=false"

# Keep the unchanged real-player test and its failure available both in the full
# log and GitHub's check annotations when the log storage requires other access.
log_file="${RUNNER_TEMP:-/tmp}/gallery-native-motion-test.log"
android_log_file="${RUNNER_TEMP:-/tmp}/gallery-native-motion-android.log"
# Clear only this disposable emulator's old log entries. Never target a physical
# device through adb's default-device selection.
if command -v adb >/dev/null 2>&1; then
  adb -s emulator-5554 logcat -c || true
fi
set +e
# Flutter's integration runner remembers the package before its first build.
# With no APK present it falls back to the source namespace, which differs from
# our Gradle applicationId. Build first so both startup and cleanup use the real
# debug APK identity. This does not install or launch the app; flutter test still
# builds its generated test entrypoint and performs the first launch itself.
# Keep DDS enabled: the pinned runner needs its custom golden-comparator stream.
{
  flutter build apk --debug --no-pub --target-platform android-x64 \
    --target integration_test/timeline_native_motion_test.dart &&
    flutter test --no-pub integration_test/timeline_native_motion_test.dart \
      -d emulator-5554 --reporter expanded
} 2>&1 | tee "$log_file"
test_status=${PIPESTATUS[0]}
set -e
if (( test_status != 0 )); then
  # A VM-service disappearance can precede every Dart assertion. Preserve the
  # Android crash/exit reason so that a startup failure is not blamed on playback
  # or "fixed" by weakening its assertions. Diagnostic errors cannot mask it.
  if command -v adb >/dev/null 2>&1; then
    {
      adb -s emulator-5554 logcat -b crash -d -v threadtime || true
      adb -s emulator-5554 logcat -d -v threadtime -t 300 \
        AndroidRuntime:E libc:F DEBUG:F flutter:I ActivityManager:I ActivityTaskManager:I lmkd:I '*:S' || true
      adb -s emulator-5554 shell dumpsys activity exit-info de.opennoodle.gallery.debug || true
    } > "$android_log_file" 2>&1
  fi
  python3 - "$log_file" "$android_log_file" <<'PY'
import sys
from pathlib import Path

tail = '\n'.join(Path(sys.argv[1]).read_text(errors='replace').splitlines()[-180:])
escaped = tail.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
print('::error title=Actual Android native timeline playback failure::' + escaped)
android_log = Path(sys.argv[2])
if android_log.exists():
    context = android_log.read_text(errors='replace')
    if len(context) > 24000:
        context = context[:12000] + '\n[truncated; full Android log retained as artifact]\n' + context[-12000:]
    escaped = context.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    print('::error title=Android startup crash and process exit evidence::' + escaped)
PY
else
  python3 - "$log_file" <<'PY'
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(errors='replace').splitlines():
    if 'Native timeline smoke:' in line:
        escaped = line.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print('::notice title=Native decoded playback evidence::' + escaped)
PY
fi
exit "$test_status"
