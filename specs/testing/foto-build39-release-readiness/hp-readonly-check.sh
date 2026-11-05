#!/usr/bin/env bash
# Compatibility wrapper; Android-only preflight. No service/container actions.
set -euo pipefail
FOTO_SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
case "${1:-}" in
  repo) shift; exec python3 "$FOTO_SCRIPT_DIR/android-preflight.py" history "$@" ;;
  sdk|apk|keys|device) exec python3 "$FOTO_SCRIPT_DIR/android-preflight.py" "$@" ;;
  *) printf 'Usage: bash hp-readonly-check.sh repo|sdk|apk|keys|device [options]\n' >&2; exit 2 ;;
esac
