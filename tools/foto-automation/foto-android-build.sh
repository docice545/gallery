#!/bin/bash
# Run only as the android-apk stage under the common heavy-stage lock.
set -euo pipefail
# Verify the lockfile first. Flutter 3.47's --no-pub also skips release-specific
# plugin registration, leaving dev-only integration_test in the Java registrant
# while Gradle correctly excludes it from the release classpath.
flutter pub get --enforce-lockfile
flutter build apk --release
