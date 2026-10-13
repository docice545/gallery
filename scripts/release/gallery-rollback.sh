#!/usr/bin/env bash
set -euo pipefail
umask 077
tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ${1:-} == --fresh-install ]]; then
  shift
  [[ $# -eq 3 && "$3" == --execute-approved ]] || {
    echo 'Usage: gallery-rollback.sh --fresh-install PACKAGE INSTALL_DIRECTORY --execute-approved' >&2
    exit 2
  }
  exec python3 -B "$tool_dir/gallery_install.py" --rollback-fresh "$@"
fi
[[ $# -ge 4 ]] || { echo 'Usage: gallery-rollback.sh PACKAGE PRIVATE_STATE PREVIOUS_RUN_ROOT NAS_EVIDENCE [--execute-approved]' >&2; exit 2; }
exec python3 -B "$tool_dir/gallery_entry.py" rollback "$@"
