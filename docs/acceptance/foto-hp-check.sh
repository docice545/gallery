#!/usr/bin/env bash
# Run from the archived handoff directory against the unchanged candidate checkout.
# No installation, production configuration, key creation or git mutation.
set -Eeuo pipefail
umask 077

mode=${1:-}
case "$mode" in
  preflight|mobile-tests|build-release|backend-tests) ;;
  *) echo 'Usage: foto-hp-check.sh preflight|mobile-tests|build-release|backend-tests' >&2; exit 2 ;;
esac
: "${FOTO_REPO:?Existing HP candidate checkout required}"
: "${FOTO_SOURCE_SHA:?Full candidate commit required}"
: "${FOTO_BRANCH:?Expected candidate branch required}"
: "${FOTO_EVIDENCE:?Existing private evidence directory required}"
[[ "$FOTO_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ -d "$FOTO_REPO/.git" && -d "$FOTO_EVIDENCE" ]] || exit 2
cd "$FOTO_REPO"
[[ "$(git rev-parse HEAD)" == "$FOTO_SOURCE_SHA" ]] || { echo 'BLOCKED: unexpected source SHA' >&2; exit 2; }
[[ "$(git branch --show-current)" == "$FOTO_BRANCH" ]] || { echo 'BLOCKED: unexpected branch' >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo 'BLOCKED: preserve existing working changes' >&2; exit 2; }
[[ -f scripts/release/android_release.py && -f scripts/release/server_artifact_smoke.py ]] || exit 2
command -v python3 >/dev/null

case "$mode" in
  preflight|build-release)
    : "${FOTO_INSTALLED:?Read actual installed Samsung versionCode first}"
    : "${FOTO_BUILD:?Explicit newer build number required}"
    [[ "$FOTO_INSTALLED" =~ ^[0-9]+$ && "$FOTO_BUILD" =~ ^[0-9]+$ ]] || exit 2
    (( FOTO_INSTALLED >= 38 && FOTO_BUILD > FOTO_INSTALLED )) || exit 2
    args=(--expected-head "$FOTO_SOURCE_SHA" --expected-branch "$FOTO_BRANCH"
      --installed-build-number "$FOTO_INSTALLED" --build-number "$FOTO_BUILD")
    if [[ "$mode" == preflight ]]; then
      python3 scripts/release/android_release.py preflight "${args[@]}"
    else
      log=$(mktemp "$FOTO_EVIDENCE/android-build-XXXXXX.log")
      echo "Private build log: $log"
      python3 scripts/release/android_release.py build "${args[@]}" >"$log" 2>&1
      python3 scripts/release/android_release.py postflight "${args[@]}" >>"$log" 2>&1
      echo 'PASS: built/reused and verified APK; installation is DEVICE_REQUIRED'
    fi
    ;;
  mobile-tests)
    log=$(mktemp "$FOTO_EVIDENCE/mobile-tests-XXXXXX.log")
    echo "Private test log: $log"
    (
      cd mobile
      bash scripts/android_media_codegen.sh
      flutter analyze --no-pub
      flutter test --no-pub --concurrency=2
      cd android
      bash gradlew :app:testDebugUnitTest --console=plain
    ) >"$log" 2>&1
    echo 'PASS: cloud-equivalent mobile tests; no device installation performed'
    ;;
  backend-tests)
    : "${FOTO_BACKEND_ARTIFACT:?Verified local artifact directory required}"
    [[ -d "$FOTO_BACKEND_ARTIFACT" ]] || exit 2
    # The existing runner verifies provenance before Docker mutation, forces a
    # local socket, creates unique disposable resources and cleans only its own.
    log=$(mktemp "$FOTO_EVIDENCE/backend-http-XXXXXX.log")
    echo "Private test log: $log"
    python3 scripts/release/server_artifact_smoke.py --local-disposable-lab \
      "$FOTO_SOURCE_SHA" "$FOTO_BACKEND_ARTIFACT" >"$log" 2>&1
    echo 'PASS: disposable backend HTTP tests; production and HP storage are untested'
    ;;
esac
