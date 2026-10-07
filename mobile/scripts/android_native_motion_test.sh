#!/usr/bin/env bash
set -euo pipefail

# Keep the unchanged real-player test and its failure available both in the full
# log and GitHub's check annotations when the log storage requires other access.
log_file="${RUNNER_TEMP:-/tmp}/gallery-native-motion-test.log"
set +e
flutter test --no-pub integration_test/timeline_native_motion_test.dart \
  -d emulator-5554 --reporter expanded 2>&1 | tee "$log_file"
test_status=${PIPESTATUS[0]}
set -e
if (( test_status != 0 )); then
  python3 - "$log_file" <<'PY'
import sys
from pathlib import Path

tail = '\n'.join(Path(sys.argv[1]).read_text(errors='replace').splitlines()[-180:])
escaped = tail.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
print('::error title=Actual Android native timeline playback failure::' + escaped)
PY
fi
exit "$test_status"
