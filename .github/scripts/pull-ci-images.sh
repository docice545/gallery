#!/usr/bin/env bash
# Retry only a hosted CI registry fetch. Never retry tests, builds, or mutations.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || {
  echo 'This helper is restricted to disposable GitHub-hosted CI.' >&2
  exit 2
}
log_file="$(mktemp)"
trap 'rm -f -- "$log_file"' EXIT
for attempt in 1 2 3; do
  set +e
  docker compose pull --ignore-buildable 2>&1 | tee "$log_file"
  pull_status=${PIPESTATUS[0]}
  set -e
  if (( pull_status == 0 )); then
    exit 0
  fi
  if (( attempt == 3 )) || ! grep -Eiq 'toomanyrequests|too many requests|status( code)?:? 429|rate.?limit|connection reset|TLS handshake timeout|i/o timeout' "$log_file"; then
    exit "$pull_status"
  fi
  echo "Transient registry fetch failed (attempt $attempt of 3); tests have not started." >&2
  # The shared registry can throttle for a complete minute. Keep the same
  # bounded three fetch attempts, allowing that window to pass before the last.
  sleep "$((attempt * 30))"
done
