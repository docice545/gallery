#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $# -ge 4 ]] || { echo 'Usage: gallery-rollback.sh PACKAGE PRIVATE_STATE PREVIOUS_RUN_ROOT NAS_EVIDENCE [--execute-approved]' >&2; exit 2; }
tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec python3 -B "$tool_dir/gallery_entry.py" rollback "$@"
