#!/usr/bin/env bash
# Copies only an owned temporary synthetic test; never updates golden baselines.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=${1:?Usage: capture-cloud-visuals.sh REPOSITORY OUTPUT_DIRECTORY}
output=${2:?Output directory required}
test -f "$repo/mobile/pubspec.yaml"
fixture=$(python3 - "$repo/mobile/test" <<'PY'
import os,sys,tempfile
fd,name=tempfile.mkstemp(prefix='foto_build38_visual_',suffix='_test.dart',dir=sys.argv[1])
os.close(fd)
print(name)
PY
)
trap 'rm -f -- "$fixture"' EXIT
cp "$here/fixtures/foto_visual_capture.dart" "$fixture"
cd "$repo/mobile"
FOTO_VISUAL_EVIDENCE="$output" flutter test --no-pub "$fixture" --reporter expanded
