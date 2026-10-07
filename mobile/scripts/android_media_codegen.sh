#!/usr/bin/env bash
# Pinned, Flutter-aware generation for native Android media verification.
set -euo pipefail
cd "$(dirname "$0")/.."
mise run //:open-api-dart
flutter pub get --enforce-lockfile
pigeon_main="$(python3 - <<'PY'
import json
from pathlib import Path
from urllib.parse import urljoin, urlparse, unquote
config = Path('.dart_tool/package_config.json').resolve()
package = next(p for p in json.loads(config.read_text())['packages'] if p['name'] == 'pigeon')
uri = urlparse(urljoin(config.as_uri(), package['rootUri']))
if uri.scheme != 'file':
    raise SystemExit('Locked Pigeon package must be local')
path = Path(unquote(uri.path)) / 'bin/pigeon.dart'
if not path.is_file():
    raise SystemExit('Locked Pigeon executable is missing')
print(path)
PY
)"
for definition in pigeon/*.dart; do
  dart --packages=.dart_tool/package_config.json "$pigeon_main" --input "$definition"
done
flutter pub run easy_localization:generate -S ../i18n
flutter pub run bin/generate_keys.dart
flutter pub run drift_dev make-migrations
flutter pub run drift_dev schema generate --data-classes --companions drift_schemas/main/ test/drift/main/generated/
flutter pub run build_runner build
dart format lib/platform/ lib/routing/router.gr.dart
