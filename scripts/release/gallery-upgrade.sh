#!/usr/bin/env bash
# Thin wrapper: compiled binary package; no source build or global Compose operations.
set -euo pipefail
umask 077
[[ $# -ge 5 ]] || { echo 'Usage: gallery-upgrade.sh prepare|check|apply|upgrade PACKAGE PRIVATE_STATE PREVIOUS_RUN_ROOT NAS_EVIDENCE [approval flags]' >&2; exit 2; }
tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec python3 -B "$tool_dir/gallery_entry.py" "$@"
