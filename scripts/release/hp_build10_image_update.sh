#!/usr/bin/env bash
# Frozen ea51a8ac image handoff. This wrapper never builds, pulls, imports,
# authorizes deletion, activates retention, or edits existing Compose files.
set -euo pipefail
umask 077

action=${1:-}
run_root=${2:-}
case "$action" in plan|check|apply|rollback|status) ;; *)
  echo 'Usage: hp_build10_image_update.sh plan|check|apply|rollback|status PRIVATE_RUN_DIRECTORY' >&2
  exit 2
esac
[[ $# == 2 ]] || { echo 'STOP EXACT_TWO_ARGUMENTS_REQUIRED' >&2; exit 2; }
[[ $(id -un) == doctoriceadm ]] || { echo 'STOP RUN_AS_DOCTORICEADM' >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tool="$script_dir/image_release.py"
[[ -f "$tool" && ! -L "$tool" ]] || { echo 'STOP VERIFIED_ADJACENT_IMAGE_TOOL_REQUIRED' >&2; exit 1; }
operator_home=$(getent passwd doctoriceadm | cut -d: -f6)
[[ "$operator_home" == /* && "$run_root" == "$operator_home"/gallery-build10-release-* && -d "$run_root" && ! -L "$run_root" ]] || {
  echo 'STOP NEW_PRIVATE_RELEASE_DIRECTORY_REQUIRED' >&2; exit 1;
}
[[ $(stat -c %a "$run_root") == 700 && $(stat -c %u "$run_root") == "$(id -u)" ]] || {
  echo 'STOP OWNED_0700_RELEASE_DIRECTORY_REQUIRED' >&2; exit 1;
}
state="$run_root/state"
log="$run_root/$action-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
# Never overwrite a previous SSH session's journal.
(set -o noclobber; : > "$log")
trap 'result_status=$?; printf "RESULT exit=%s action=%s\n" "$result_status" "$action" | tee -a "$log"; exit "$result_status"' EXIT
run_tool() { python3 -B "$tool" "$@" 2>&1 | tee -a "$log"; }

if [[ "$action" == plan ]]; then
  [[ ! -e "$state" && ! -L "$state" ]] || { echo 'STOP NEVER_REUSE_PREVIOUS_STATE' >&2; exit 1; }
  mkdir -m 700 -- "$state"
  run_tool plan --sudo-docker --state "$state" \
    --image sha256:4d4f9d581a654713b6d305f9aa1341b302fd36fc4ef7fca832dcb94de4004e75 \
    --expected-current-image sha256:828523317c332cb312246c9b0ca43e0eef1eb724f7f9aadb58c61b7f87068f43 \
    --source-commit ea51a8acdc6f18ab5917c19b6f3833d740b4e9ba --server-version 5.7.3
fi

# Check the exact release binding and protect local evidence. Back up only
# existing Compose inputs, never media, databases, mounts or unrelated services.
python3 -B - "$tool" "$state" "$run_root" "$action" <<'PY'
import hashlib, importlib.util, json, os, pathlib, sys
spec = importlib.util.spec_from_file_location('image_handoff', sys.argv[1])
tool = importlib.util.module_from_spec(spec); spec.loader.exec_module(tool)
state, root, action = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4]
try:
    tool.need(state.is_dir() and not state.is_symlink() and state.stat().st_mode & 0o777 == 0o700,
              'PRIVATE_PLAN_STATE_REQUIRED')
    receipt = tool.private_json(state / 'image-plan.json')
    tool.need(receipt['candidateImage'] == 'sha256:4d4f9d581a654713b6d305f9aa1341b302fd36fc4ef7fca832dcb94de4004e75' and
              receipt['sourceCommit'] == 'ea51a8acdc6f18ab5917c19b6f3833d740b4e9ba' and
              receipt['previousImage'] == 'sha256:828523317c332cb312246c9b0ca43e0eef1eb724f7f9aadb58c61b7f87068f43' and
              receipt['serverVersion'] == {'major': 5, 'minor': 7, 'patch': 3, 'prerelease': None} and
              receipt.get('configHashMode') == tool.CONFIG_HASH_MODE, 'EXACT_BUILD10_PLAN_REQUIRED')
    if action == 'plan':
        backup = root / 'compose-input-backups'; backup.mkdir(mode=0o700)
        index = []
        for number, (path, expected) in enumerate(receipt['fileHashes'].items()):
            data = pathlib.Path(path).read_bytes()
            tool.need(hashlib.sha256(data).hexdigest() == expected, 'COMPOSE_INPUT_CHANGED_BEFORE_BACKUP')
            name = f'input-{number}.backup'
            with os.fdopen(os.open(backup / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'wb') as out:
                out.write(data); out.flush(); os.fsync(out.fileno())
            index.append({'original': path, 'backup': name, 'sha256': expected})
        tool.save(backup / 'index.json', index)
    if action in ('check', 'apply', 'rollback'):
        tool.need(not receipt.get('migrationsAdded'), 'MIGRATIONS_REQUIRE_SEPARATE_BACKUP_AND_APPROVAL_WORKFLOW')
    if action == 'status':
        for name in ('applied.json', 'rolled-back.json'):
            path = state / name
            if path.exists():
                saved = tool.private_json(path)
                print('RECORDED_PASS', name, saved['image'], saved['completedAt'])
        if (state / 'rollback-attempt.json').exists() and not (state / 'rolled-back.json').exists():
            raise tool.Stop('ROLLBACK_ATTEMPT_INCOMPLETE_DO_NOT_REPEAT')
        if (state / 'apply-attempt.json').exists() and not (state / 'applied.json').exists():
            raise tool.Stop('UPDATE_ATTEMPT_INCOMPLETE_REVIEW_ROLLBACK')
        if not (state / 'apply-attempt.json').exists():
            print('PLANNED_ONLY_NOT_DEPLOYED')
except Exception as error:
    print('STOP ' + (str(error) if isinstance(error, tool.Stop) else 'PRIVATE_HANDOFF_DETAILS_OMITTED'), file=sys.stderr)
    raise SystemExit(1)
PY

case "$action" in
  plan|check) run_tool apply --sudo-docker --state "$state" ;;
  apply|rollback)
    # Recheck before requesting approval of the concrete validated plan.
    run_tool "$action" --sudo-docker --state "$state"
    echo 'Fresh recoverable PostgreSQL backup and empty verified AssetDelete/FileDelete queues are required.'
    echo 'No retention or deletion authorization is granted by this image update.'
    read -r -p "Type '$action ea51a8ac' after reviewing the plan and safety prerequisites: " approval
    [[ "$approval" == "$action ea51a8ac" ]] || { echo 'STOP OPERATOR_DID_NOT_APPROVE' >&2; exit 1; }
    GALLERY_DEPLOYMENT_APPROVED=YES run_tool "$action" --sudo-docker --state "$state" --execute-approved
    ;;
  status) ;;
esac
printf 'PASS %s; state=%s; private log=%s\n' "$action" "$state" "$log"
