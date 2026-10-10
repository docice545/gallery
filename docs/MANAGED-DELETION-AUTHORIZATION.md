# Managed deletion authorization: review and operator instructions

This patch is based on Gallery 5.7.2 (9). Review it before building a new release.
The existing build 9 artifacts do **not** contain the new consent UI. No release
APK, production Docker image or production deployment is produced by this task.

## Authorization in the app and web

Open Trash → ⋮ → **Разрешение окончательного удаления** in the mobile app.
On web, expand that section in Trash.

- The account administrator first verifies backup restoration and exclusive managed
  roots, supplies the SHA-256 of the real private recovery report and confirms the
  attestation. **Проверить managed storage** stores a disabled policy; it does not
  delete files or grant consent.
- The owner selects **Разрешить удаление из managed storage** and confirms the
  irreversible-deletion warning. No owner/library/root selection is accepted by
  this operation. A non-admin asks their existing administrator to prepare their
  disabled managed policy through the existing admin API, then grants consent.
- **Отозвать разрешение** disables managed deletion without requiring storage access.
- Empty Trash and selective deletion require the same policies. If an external
  scope is blocked, no new files in that selection are deleted. Select managed
  items separately. No external policy is automatically enabled.
- Preparation proves neither recovery nor exclusive ownership by entering an
  arbitrary hash. Use the actual, reviewed recovery evidence. A managed original
  can be physically on Synology; confirm that evidence covers its actual roots.

The 291 offline external index records remain unchanged and outside user Trash.
No SQL conversion is required. Existing policy/receipt tables are reused; **no new
migration is needed**. The 12 managed Trash assets remain restorable until an
explicit authorized permanent-deletion operation succeeds.

## Deployment after separate review and approval

1. Review the patch and automatic checks. Assign the next approved mobile build
   number, preserving package/bundle identities, HP certificate and SideStore
   extensions. Build backend, Android and unsigned iOS from the **same** reviewed
   application SHA using existing workflows. Do not reuse build 9 artifacts as if
   they contained this patch. Signing and device acceptance remain separate gates.
2. Preserve verified PostgreSQL/NAS recovery evidence; make and validate a fresh
   database backup using the existing recovery tooling. Record current image ID
   and Compose files securely. Recheck AssetDelete/FileDelete jobs in every state
   using the existing bounded inventory, not SCAN alone. Unexpected jobs or
   incomplete inventory mean STOP; no automatic clearing or retry.
3. Review image config/layers/manifest/checksum and migration compatibility before
   loading it. Keep the previous image locally for rollback. Do not remove volumes,
   reset the schema, prune Docker or change mounts. This patch has no schema change.
4. Update only the server's image through an **image-only** Compose override added
   last to the actual, verified Compose invocation. Keep every other field/service
   unchanged. Do **not** use historical `trash_release.py deploy/rollback` actions
   that install API-only worker overrides. Do not run `enable-workers` as a proxy
   for thumbnail repair or retention authorization.

After approval and verified artifacts, the actual Compose invocation recorded
from production supplies the variables below. Missing inputs stop execution.
`COMPOSE_FILES` contains each original file in its original order. No credential
or `.env` value is printed. This is a deployment template, not authorization to run it.

```bash
set -euo pipefail
umask 077
: "${APPROVED_IMAGE:?Immutable, verified new image reference required}"
: "${EXPECTED_IMAGE_ID:?Verified loaded image config ID required}"
: "${COMPOSE_PROJECT:?Use actual recorded Compose project}"
: "${COMPOSE_DIRECTORY:?Use actual recorded Compose directory}"
: "${SERVER_SERVICE:?Use actual server service name}"
: "${RELEASE_STATE:?New private operator state directory required}"
# Define COMPOSE_FILES as a Bash array of verified original files before this block.
[[ ${#COMPOSE_FILES[@]} -gt 0 ]]
[[ "$(sudo docker image inspect --format '{{.Id}}' "$APPROVED_IMAGE")" == "$EXPECTED_IMAGE_ID" ]]
[[ -d "$RELEASE_STATE" && "$(stat -c %a "$RELEASE_STATE")" == 700 ]]
[[ ! -e "$RELEASE_STATE/image-only.override.json" ]]
export APPROVED_IMAGE SERVER_SERVICE RELEASE_STATE
python3 - <<'PY'
import json, os
from pathlib import Path
p = Path(os.environ['RELEASE_STATE']) / 'image-only.override.json'
with p.open('x') as f:
    json.dump({'services': {os.environ['SERVER_SERVICE']: {'image': os.environ['APPROVED_IMAGE']}}}, f)
p.chmod(0o600)
PY
BASE=(sudo docker compose --project-directory "$COMPOSE_DIRECTORY" -p "$COMPOSE_PROJECT")
for file in "${COMPOSE_FILES[@]}"; do
  [[ -f "$file" ]]
  BASE+=(-f "$file")
done
# Verify the effective diff privately; never print Compose environment values.
python3 - "$RELEASE_STATE" "$SERVER_SERVICE" "$APPROVED_IMAGE" "${BASE[@]:1}" <<'PY_CONFIG'
import copy, json, os, subprocess, sys
from pathlib import Path
state, service, image = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
base = ['sudo', *sys.argv[4:]]
read = lambda args: json.loads(subprocess.check_output(args, stderr=subprocess.DEVNULL))
before = read([*base, 'config', '--format', 'json'])
after = read([*base, '-f', str(state / 'image-only.override.json'), 'config', '--format', 'json'])
assert service in before['services'], 'STOP: unknown server service'
assert after['services'][service]['image'] == image, 'STOP: wrong target image'
expected = copy.deepcopy(before)
expected['services'][service]['image'] = image
assert after == expected, 'STOP: changes beyond the server image'
env = after['services'][service].get('environment', {})
include = set(filter(None, str(env.get('IMMICH_WORKERS_INCLUDE') or '').split(',')))
exclude = set(filter(None, str(env.get('IMMICH_WORKERS_EXCLUDE') or '').split(',')))
assert not include or {'api', 'microservices'} <= include, 'STOP: API/microservices excluded'
assert not {'api', 'microservices'} & exclude, 'STOP: API/microservices excluded'
print('PASS image-only Compose difference; API + microservices configured')
PY_CONFIG
"${BASE[@]}" -f "$RELEASE_STATE/image-only.override.json" \
  up -d --no-deps --no-build --pull never "$SERVER_SERVICE"
```

Do not reintroduce `IMMICH_WORKERS_INCLUDE=api` or
`IMMICH_WORKERS_EXCLUDE=microservices`. Both API and microservices workers must
run unless a separate healthy microservices service is explicitly configured.
Do not change retention policy or authorize external deletion during deployment.

## Mandatory acceptance (not yet verified on production/devices)

Use disposable fixtures only, and each existing user account separately.

1. Server healthy; API version/source/image correct. Logs show API worker and
   microservices worker running, with no “No microservices worker is connected”.
2. Upload a disposable screenshot through Android/web. Wait for background processing;
   check thumbnail **and** preview availability with the authenticated image APIs;
   both return valid image bytes. Open the photo on Android and web without gray
   tiles/white viewer. Job completion, not worker startup alone, establishes PASS.
3. Confirm genuine managed Trash is visible, offline index entries excluded, dates
   preserved. With no policy, selective deletion is blocked and the file survives.
4. Prepare disabled managed scope → explicit owner consent → permanently delete
   one disposable managed photo/video. Verify actual original/paired-resource
   outcomes and receipt; another user's files must remain unchanged.
5. Select managed + unapproved external fixtures: no unlink and clear per-scope
   explanation. Test Empty Trash on a disposable account with only authorized
   fixtures; never empty a real family account for acceptance.
6. Revoke consent, retry deletion, test interrupted request/restart, restore and
   chronological timeline placement. Test OS denial and local-copy reporting on
   S23/iPhone, including Live/Motion media. No physical-device PASS is claimed here.
7. Thumbnail/preview jobs, albums, search, viewing and synchronization continue
   after server restart. Automatic retention stays disabled by the existing guard.

## Rollback

Before rollback, explicitly revoke the new managed consent through the UI/API
(if unavailable, the existing admin policy API with `enabled:false`). Do not drop
policies/tombstones or replay queues. Keep external authorization unchanged.
Use the same image-only procedure with the recorded previous immutable image,
config image ID and a **new** private rollback state directory. Keep the original
Compose invocation and healthy API + microservices configuration. Verify server
health and fresh thumbnail/preview processing again. Old clients/backend remain
schema compatible, but the new consent UI requires the new endpoints.

Rollback cannot undo completed unlink operations. Restoring a removed original
requires the already verified NAS/managed backup and an individually approved
recovery procedure; do not replace the entire live database or discard newer
uploads. No destructive schema rollback, global Docker cleanup or API-only worker
gate is part of this procedure.
