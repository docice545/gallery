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

# Flutter names the archive after PRODUCT_NAME, which branding can change.
# Clear only this project's owned archive outputs before building, so neither
# a stale canonical nor a stale branded archive can satisfy verification.
archive_dir="$mobile_dir/build/ios/archive"
archive="$archive_dir/Runner.xcarchive"
app_metadata="$(python3 - "$mobile_dir/pubspec.yaml" <<'PY'
import re
import sys
from pathlib import Path

version = re.search(r'^version: (\d+\.\d+\.\d+)\+(\d+)\s*$', Path(sys.argv[1]).read_text(), re.MULTILINE)
if not version:
    raise SystemExit('Flutter application version/build is missing or invalid')
print(*version.groups())
PY
)"
read -r app_version app_build <<< "$app_metadata"
python3 - "$archive_dir" <<'PY'
import shutil
import sys
from pathlib import Path

directory = Path(sys.argv[1])
if directory.is_symlink():
    raise SystemExit('Refusing cleanup of a symlinked archive output directory')
for previous in directory.glob('*.xcarchive'):
    if previous.is_symlink() or previous.is_file():
        previous.unlink()
    elif previous.is_dir():
        shutil.rmtree(previous)
PY
mise exec -- flutter build ipa --release --no-codesign --build-name="$app_version" --build-number="$app_build"

# Require exactly one fresh, real archive, then keep the existing canonical
# artifact contract. Renaming the outer archive leaves all bundle identities,
# display names and compiled contents unchanged.
python3 - "$archive_dir" "$archive" <<'PY'
import sys
from pathlib import Path

directory, canonical = map(Path, sys.argv[1:])
archives = list(directory.glob('*.xcarchive'))
if not archives:
    raise SystemExit('iOS archive verification failed: Expected Runner.xcarchive is missing (no fresh Flutter archive)')
if len(archives) != 1:
    raise SystemExit(f'Expected exactly one fresh Flutter archive, found {len(archives)}')
generated = archives[0]
if generated.is_symlink() or not generated.is_dir():
    raise SystemExit('Fresh Flutter archive must be a directory, not a symlink')
if generated != canonical:
    generated.rename(canonical)
    print('Normalized fresh Flutter product archive to Runner.xcarchive.')
PY
python3 "$mobile_dir/scripts/verify_ios_archive.py" "$archive" \
  --branding-config "$repo_dir/branding/config.json" \
  --expected-version "$app_version" --expected-build "$app_build" \
  --app-icon-catalog "$mobile_dir/ios/Runner/Assets.xcassets/AppIcon.appiconset"
echo "Unsigned build-only archive verified: $archive"
echo "::notice title=iOS unsigned archive verified::Runner and both extensions verified; $app_version ($app_build); Flutter $actual_flutter."

# No signing/export credentials: package only the verified compiled app. The
# user-side Personal Team/SideStore pilot signs this IPA before installation.
unsigned_ipa="$mobile_dir/build/ios/ipa/Photos-unsigned.ipa"
python3 "$mobile_dir/scripts/package_unsigned_ios.py" "$archive" "$unsigned_ipa" \
  --branding-config "$repo_dir/branding/config.json" \
  --expected-version "$app_version" --expected-build "$app_build" \
  --app-icon-catalog "$mobile_dir/ios/Runner/Assets.xcassets/AppIcon.appiconset"
