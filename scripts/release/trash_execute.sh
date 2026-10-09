#!/usr/bin/env bash
# Operator wrapper only. Nothing changes unless a specific action is selected.
set -euo pipefail
[[ $# == 7 ]] || { echo 'Usage: trash_execute.sh ACTION STATE ARTIFACTS AUDIT SQL_GZIP_BACKUP NAS_PROOF ADMIN_KEY_FILE' >&2; exit 2; }
action="$1"; state="$2"; artifacts="$3"; audit="$4"; backup="$5"; nas="$6"; key="$7"
[[ "$(id -un)" == doctoriceadm ]] || { echo 'FAIL run as doctoriceadm'; exit 1; }
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -d "$state" && "$(stat -c %a -- "$state")" == 700 ]] || { echo 'FAIL existing private 0700 state required'; exit 1; }
for tool in python3 docker; do command -v "$tool" >/dev/null || { echo "FAIL missing $tool"; exit 1; }; done
common=(--state "$state" --audit "$audit" --key "$key")
case "$action" in
  verify)
    python3 "$root/trash_release.py" verify-artifact "${common[@]}" --artifact "$artifacts/backend"
    python3 - "$artifacts" <<'PY'
import hashlib, pathlib, sys
root=pathlib.Path(sys.argv[1])
for relative, expected in (
 ('android/app-release.apk','ae3ed08bfe8794e1f12193e5d29733c22c22e7671672726e1a27b869483a4527'),
 ('ios/Photos-unsigned.ipa','4abfdbd7007c5f72d85fbb2cc8b35c20891c7342d2c9e6cba85c23792278a6bd')):
    with (root/relative).open('rb') as file:
        if hashlib.file_digest(file,'sha256').hexdigest()!=expected:
            raise SystemExit('FAIL frozen mobile artifact checksum mismatch')
print('PASS Android/iOS frozen 6a558b55 artifacts; no rebuild')
PY
    ;;
  recover)
    [[ "${GALLERY_RECOVERY_APPROVED:-}" == YES ]] || { echo 'STOP isolated recovery validation requires approval'; exit 1; }
    python3 "$root/trash_release.py" nas-check "${common[@]}" --nas-proof "$nas" --execute-approved
    python3 "$root/trash_release.py" restore-check "${common[@]}" --backup "$backup" --execute-approved
    ;;
  deploy|acceptance|rollback)
    [[ "${GALLERY_DEPLOYMENT_APPROVED:-}" == YES ]] || { echo 'STOP production execution requires explicit approval'; exit 1; }
    python3 "$root/trash_release.py" "$action" "${common[@]}" --artifact "$artifacts/backend" --execute-approved
    ;;
  enable-workers)
    [[ "${GALLERY_DEPLOYMENT_APPROVED:-}" == YES && "${GALLERY_RETENTION_RESUME_APPROVED:-}" == YES ]] || { echo 'STOP separate retention resume approval required'; exit 1; }
    python3 "$root/trash_release.py" enable-workers "${common[@]}" --execute-approved --retention-approved
    ;;
  sign-android)
    [[ "${GALLERY_SIGNING_APPROVED:-}" == YES ]] || { echo 'STOP HP production signing requires explicit approval'; exit 1; }
    # Existing SDK/JDK/keystore/cache locations; no build, new key or installation.
    : "${JAVA_HOME:?Set the existing HP JDK 17 path}"
    : "${ANDROID_HOME:?Set the existing HP Android SDK path}"
    python3 "$root/android_release.py" sign-existing --repository /opt/gallery-fork \
      --expected-head 6a558b554e26e8c0fc5bc5c99259a92e7ef26a56 --build-number 8 \
      --input-apk "$artifacts/android/app-release.apk" --authorize-production-signing
    ;;
  *) echo 'FAIL unknown action; nothing executed' >&2; exit 2 ;;
esac
