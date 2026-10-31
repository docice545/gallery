#!/bin/bash
# Run only as the android-apk stage under the common heavy-stage lock.
set -euo pipefail
# Verify the lockfile first. Flutter 3.47's --no-pub also skips release-specific
# plugin registration, leaving dev-only integration_test in the Java registrant
# while Gradle correctly excludes it from the release classpath.
if [[ "${FOTO_PUB_OFFLINE:-0}" == 1 ]]; then
  # An explicit offline resolution refreshes pub's package_config and Flutter
  # version stamp. Flutter 3.47.2's cached build pub check then skips resolution
  # ("Skipping pub get: version match") but STILL regenerates release plugins.
  flutter pub get --offline --enforce-lockfile
else
  flutter pub get --enforce-lockfile
fi
flutter build apk --release
