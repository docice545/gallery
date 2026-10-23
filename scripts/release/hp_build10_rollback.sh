#!/usr/bin/env bash
# Pinned fallback artifact + unchanged image-only release safeguards.
set -euo pipefail
umask 077
action=${1:-}
run_root=${2:-}
[[ $# == 2 ]] || { echo 'STOP EXACT_TWO_ARGUMENTS_REQUIRED' >&2; exit 2; }
case "$action" in continue|prepare|prepare-images|check|apply|rollback|status) ;; *)
  echo 'Usage: hp_build10_rollback.sh continue|prepare|check|apply|rollback|status PRIVATE_RUN_DIRECTORY' >&2
  exit 2
esac
[[ $(id -un) == doctoriceadm ]] || { echo 'STOP RUN_AS_DOCTORICEADM' >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tool="$script_dir/hp_build10_rollback.py"
# The operator must first check this checksum manifest against the pinned handoff.
(cd "$script_dir"; sha256sum --check --strict build10-rollback-tooling.sha256)
operator_home=$(getent passwd doctoriceadm | cut -d: -f6)
[[ "$run_root" == "$operator_home"/gallery-build10-release-* && "$run_root" != *'/../'* &&
   -d "$run_root" && ! -L "$run_root" && $(stat -c %a "$run_root") == 700 &&
   $(stat -c %u "$run_root") == "$(id -u)" ]] || { echo 'STOP OWNED_0700_RELEASE_DIRECTORY_REQUIRED' >&2; exit 1; }
log="$run_root/rollback-$action-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
(set -o noclobber; : > "$log")
result_status=0
trap 'result_status=$?; printf "RESULT exit=%s action=%s\n" "$result_status" "$action" | tee -a "$log"; exit "$result_status"' EXIT
run_tool() { python3 -B "$tool" "$@" --run-root "$run_root" --sudo-docker 2>&1 | tee -a "$log"; }

prepare() {
  # No credentials are read/printed; gh uses the operator's existing authentication.
  local metadata artifact_id expected zip
  metadata=$(python3 -B - "$tool" <<'PY'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location('hp_rollback_meta', sys.argv[1])
tool = importlib.util.module_from_spec(spec); spec.loader.exec_module(tool)
tool.need(isinstance(tool.CI_ARTIFACT, int) and tool.CI_ARTIFACT > 0 and
          isinstance(tool.ZIP_SHA256, str) and re.fullmatch('[0-9a-f]{64}', tool.ZIP_SHA256),
          'COMPLETED_PINNED_CI_ARTIFACT_REQUIRED')
print(tool.CI_ARTIFACT, tool.ZIP_SHA256)
PY
  )
  read -r artifact_id expected <<< "$metadata"
  zip="$run_root/hardened-rollback-$artifact_id.zip"
  if [[ -e "$zip" || -L "$zip" ]]; then
    [[ -f "$zip" && ! -L "$zip" && $(stat -c %a "$zip") == 600 &&
       $(stat -c %u "$zip") == "$(id -u)" ]] || { echo 'STOP PRIVATE_ZIP_REQUIRED'; return 1; }
  else
    local temporary
    command -v gh >/dev/null || { echo 'STOP EXISTING_GH_AUTH_OR_MANUAL_PINNED_ARTIFACT_REQUIRED'; return 1; }
    temporary=$(mktemp "$run_root/rollback-download-XXXXXXXX.part")
    # gh errors can include a temporary signed storage URL. Never echo it to
    # the terminal/journal; a failed download cannot proceed to prepare/apply.
    if ! gh api "repos/docice545/gallery/actions/artifacts/$artifact_id/zip" > "$temporary" 2>/dev/null; then
      echo 'STOP PINNED_ARTIFACT_DOWNLOAD_FAILED_CHECK_EXISTING_GH_AUTH_AND_ARTIFACT_AVAILABILITY'
      return 1
    fi
    printf '%s  %s\n' "$expected" "$temporary" | sha256sum --check --strict
    # Never overwrite a file that appeared during download.
    ln -- "$temporary" "$zip"
    # Keep the private .part as the exact downloaded bytes; no cleanup of old evidence.
  fi
  printf '%s  %s\n' "$expected" "$zip" | sha256sum --check --strict
  run_tool "${1:-prepare}" --artifact-zip "$zip"
}

if [[ "$action" == continue ]]; then
  if [[ -e "$run_root/hardened-rollback" || -L "$run_root/hardened-rollback" ]]; then
    # A failed or unfinished prepare is retained, never replaced or retried silently.
    run_tool check
  else
    prepare
  fi
  action=apply
fi
case "$action" in
  prepare|prepare-images) prepare "$action" ;;
  check|status) run_tool "$action" ;;
  apply|rollback)
    # Concrete verified dry-run before approval; the helper rechecks under lock.
    run_tool "$action"
    printf '%s\n' 'Required: current recoverable PostgreSQL backup + genuine NAS recovery evidence.'
    printf '%s\n' 'Fallback is 5.7.3 hardened prior preparation API; cross-owner admin preparation is unavailable only on fallback.'
    printf '%s\n' 'Only the server image changes. No retention activation or owner deletion consent is granted.'
    read -r -p "Type '$action ea51a8ac' only after PASS and reviewing the rollback scope: " approval
    [[ "$approval" == "$action ea51a8ac" ]] || { echo 'STOP OPERATOR_DID_NOT_APPROVE'; exit 1; }
    GALLERY_DEPLOYMENT_APPROVED=YES run_tool "$action" --execute-approved
    run_tool status
    ;;
esac
printf 'PASS %s; private journal=%s\n' "$action" "$log"
