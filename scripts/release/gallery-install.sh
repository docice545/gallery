#!/usr/bin/env bash
# Fresh installation only. Existing HP deployments use gallery-upgrade.sh.
set -euo pipefail
umask 077
[[ $# -ge 5 && "$5" == --execute-approved ]] || {
  echo 'Usage: gallery-install.sh PACKAGE NEW_EMPTY_DIRECTORY PRIVATE_ENV_FILE VERIFIED_ML_IMAGE_ID --execute-approved [--nas-storage-config PRIVATE_JSON]' >&2
  exit 2
}
[[ ${GALLERY_FRESH_INSTALL_APPROVED:-} == YES ]] || { echo 'STOP EXPLICIT_FRESH_INSTALL_APPROVAL_REQUIRED' >&2; exit 1; }
tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec python3 -B "$tool_dir/gallery_install.py" "$@"
