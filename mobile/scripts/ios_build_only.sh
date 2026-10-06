#!/usr/bin/env bash
# Compile Runner + both extensions without signing, exporting or publishing.
set -euo pipefail

mode="${1:-}"
if [[ "$#" -gt 1 || ( "$mode" != '' && "$mode" != '--prepare-only' && "$mode" != '--skip-prepare' && "$mode" != '--refresh-pods-lock' ) ]]; then
  echo 'Usage: ios_build_only.sh [--prepare-only|--skip-prepare|--refresh-pods-lock]' >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'NEEDS_MAC_VALIDATION: this lane requires macOS/Xcode.' >&2
  exit 1
fi

mobile_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$mobile_dir/.." && pwd)"
cd "$mobile_dir"

for executable in mise python3 xcodebuild; do
  command -v "$executable" >/dev/null || { echo "Missing required tool: $executable" >&2; exit 1; }
done
xcodebuild -version

# Mise owns the Flutter/Dart/Java/OpenAPI pins. Refuse a stale SDK on PATH.
flutter_pin="$(python3 - "$mobile_dir/mise.toml" "$mobile_dir/pubspec.yaml" <<'PY'
import re
import sys
from pathlib import Path

config = Path(sys.argv[1]).read_text()
section = re.search(r'^\[tools\."aqua:flutter/flutter"\]\s*\n(.*?)(?=^\[|\Z)', config, re.MULTILINE | re.DOTALL)
version = re.search(r'^version\s*=\s*"([^"]+)"\s*$', section.group(1), re.MULTILINE) if section else None
if not version:
    raise SystemExit('Flutter project pin is missing')
pin = version.group(1)
pubspec = re.search(r'^  flutter: (\S+)\s*$', Path(sys.argv[2]).read_text(), re.MULTILINE)
if not pubspec or pubspec.group(1) != pin:
    raise SystemExit('Flutter pins in mise.toml and pubspec.yaml disagree')
print(pin)
PY
)"
actual_flutter="$(mise exec -- flutter --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')"
if [[ "$actual_flutter" != "$flutter_pin" ]]; then
  echo "Flutter version mismatch: expected $flutter_pin, got $actual_flutter" >&2
  exit 1
fi

if [[ "$mode" != '--skip-prepare' ]]; then
  mise exec -- flutter config --no-enable-swift-package-manager
  mise exec -- flutter precache --ios
  mise run //:open-api-dart
  mise exec -- flutter pub get --enforce-lockfile

  # Resolve the locked Pigeon package, rather than a machine-specific pub-cache
  # path. Direct execution is Flutter-aware on SDKs where `dart run` resolution
  # cannot resolve the Flutter SDK dependency.
  pigeon_main="$(python3 - "$mobile_dir/.dart_tool/package_config.json" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse

config = Path(sys.argv[1]).resolve()
packages = json.loads(config.read_text())['packages']
package = next(item for item in packages if item['name'] == 'pigeon')
uri = urlparse(urljoin(config.as_uri(), package['rootUri']))
if uri.scheme != 'file':
    raise SystemExit('Pigeon must resolve to a local locked package')
main = Path(unquote(uri.path)) / 'bin/pigeon.dart'
if not main.is_file():
    raise SystemExit('Locked Pigeon executable is missing')
print(main)
PY
)"
  for definition in pigeon/*.dart; do
    mise exec -- dart --packages=.dart_tool/package_config.json "$pigeon_main" --input "$definition"
  done
  mise exec -- dart format lib/platform/
  mise exec -- flutter pub run easy_localization:generate -S ../i18n
  mise exec -- flutter pub run bin/generate_keys.dart
  mise exec -- flutter pub run drift_dev make-migrations
  mise exec -- flutter pub run drift_dev schema generate --data-classes --companions drift_schemas/main/ test/drift/main/generated/
  mise exec -- flutter pub run build_runner build
  mise exec -- dart format lib/routing/router.gr.dart

  # Normal builds are frozen. Maintenance explicitly regenerates a stale graph
  # with `pod install` (preserving existing locked versions), then verifies it.
  # The resulting Podfile.lock must be reviewed/committed before a normal build.
  if [[ "$mode" == '--refresh-pods-lock' ]]; then
    (cd ios && bundle exec pod install && bundle exec pod install --deployment)
  else
    (cd ios && bundle exec pod install --deployment)
  fi
fi
if [[ "$mode" == '--prepare-only' || "$mode" == '--refresh-pods-lock' ]]; then
  exit 0
fi

# Remove only the lane's previous archive, so a successful command that produced
# no new artifact cannot accidentally pass using an old build.
archive="$mobile_dir/build/ios/archive/Runner.xcarchive"
if [[ -e "$archive" || -L "$archive" ]]; then
  rm -rf -- "$archive"
fi
mise exec -- flutter build ipa --release --no-codesign
python3 "$mobile_dir/scripts/verify_ios_archive.py" "$archive" --branding-config "$repo_dir/branding/config.json"
echo "Unsigned build-only archive verified: $archive"
echo "::notice title=iOS unsigned archive verified::Runner and both extensions verified; Flutter $actual_flutter."
