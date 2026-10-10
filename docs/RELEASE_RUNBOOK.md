# Gallery 5.7.2 (9): release runbook

Application source: `76bbcf708e12ee811041adcc38fd7909a7d6da15`, branch
`candidate/gallery-trash-full-delete-5.7.2-build9`. Production `work` stays at
`42790b06edc21438811e56e40c431eee37c24894`. Tooling has its own commit; it must
never be substituted for the application/artifact SHA.

This runbook prepares existing CI artifacts. It does not authorize deployment,
merge, signing, retention, NAS permission changes or destructive tests on family
media. The October 2 docice managed-photo deletion is historical evidence for
that one asset, not acceptance for other users, external libraries or phones.

## 1. Immutable handoff and HP preparation

Obtain the successful proof run ID and `release-manifest.json` SHA-256 from the
final handoff. The artifact is `gallery-trash-frozen-handoff-RUN_ID`. Run the
following **preparation only** block as `doctoriceadm`. Existing GitHub access,
Python 3.11+, Docker, sufficient local disk/RAM and cached PostgreSQL image are
prerequisites. No dependencies are installed. No existing evidence is overwritten.

```bash
set -euo pipefail
umask 077
[[ "$(id -un)" == doctoriceadm ]]
: "${HANDOFF_RUN:?Set the exact successful proof run ID from the handoff}"
: "${EXPECTED_MANIFEST_SHA256:?Set the handoff manifest SHA-256}"
[[ "$HANDOFF_RUN" =~ ^[1-9][0-9]+$ ]]
[[ "$EXPECTED_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]]
ARTIFACTS="$(mktemp -d /home/doctoriceadm/gallery-build9-handoff-XXXXXXXX)"
chmod 700 "$ARTIFACTS"
gh run download "$HANDOFF_RUN" --repo docice545/gallery \
  --name "gallery-trash-frozen-handoff-$HANDOFF_RUN" --dir "$ARTIFACTS"
(
  cd "$ARTIFACTS"
  printf '%s  release-manifest.json\n' "$EXPECTED_MANIFEST_SHA256" | sha256sum --check --status
  sha256sum --check --status SHA256SUMS
)
PROFILE="$ARTIFACTS/candidate-profile.json"
PROFILE_SHA="$(sha256sum "$PROFILE" | cut -d' ' -f1)"
PREDEPLOY="$ARTIFACTS/tooling/trash_predeploy.py"
PINNED=/home/doctoriceadm/gallery-trash-release-tooling-565ef38/trash_release.py
printf '%s  %s\n' 56c12526736e51abad3adf321c0b9665ec9b70f8472641af966feba4c45f7a2c "$PINNED" | sha256sum --check --status
python3 -B - "$ARTIFACTS" <<'PY_VALIDATE'
import ast,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); profile=json.loads((root/'candidate-profile.json').read_text())
assert profile['sourceCommit']=='76bbcf708e12ee811041adcc38fd7909a7d6da15'
assert (profile['serverVersion'],profile['mobileVersion'],profile['mobileBuild'])==('5.7.2','5.7.2',9)
for file in (root/'tooling').rglob('*.py'): ast.parse(file.read_text())
print('PASS exact candidate and tooling syntax')
PY_VALIDATE
# Loads only the verified artifact into the local image store; no service starts.
# Use existing Docker access (or the existing approved sudo -n docker command).
docker --host=unix:///var/run/docker.sock load -i "$ARTIFACTS/backend/gallery-server-linux-amd64.tar.gz"
python3 -B "$PREDEPLOY" prepare --artifacts "$ARTIFACTS" --pinned-tool "$PINNED" \
  --candidate-profile "$PROFILE" --candidate-profile-sha256 "$PROFILE_SHA"
printf 'ARTIFACTS=%s\nPROFILE_SHA=%s\n' "$ARTIFACTS" "$PROFILE_SHA"
```

Preparation requires the existing complete audit and NAS proof. It preserves
original timestamps and the old PostgreSQL PASS, but creates a **new** SQL/gzip
backup and validates that exact backup in a new disposable PostgreSQL instance.
The candidate migration and previous API rollback startup run against that same
isolated restore, with no production network, mounts or ports. Asset/status/album
schema integrity and migration inventories must remain consistent. All policies
start disabled. A unique rollback overlay changes only two migration-recognition
files in the previous immutable image; parent layers/config and exported bytes
are checked, saved and hashed. No old deletion workers are started.

Existing evidence paths:

- `/home/doctoriceadm/gallery-trash-release-audit-20261009T155251367898Z-8d189795a83d.txt`
- `/home/doctoriceadm/gallery-nas-recovery-sau5r5go`
- `/home/doctoriceadm/gallery-recovery-hum85h39`

PASS is a preparation receipt, **not deployment approval**. Missing/expired
recovery (NAS 24 h, fresh DB backup 1 h), mismatched image/config/source/migrations,
insufficient disk/RAM, nonempty/unknown queues or changed production means STOP.
Queue emptiness uses atomic state cardinalities plus bounded legacy inventory;
SCAN alone is insufficient. Empty means empty at that instant only.

Keep the printed new `STATE` directory and all private evidence/logs. Do not
edit failed states or receipt timestamps. A failure requires its actual cause to
be resolved; do not rerun into the same state or silently reuse an old restore.

## 2. Separately approved backend deployment

Do not execute until the owner approves **deployment and the additive migration**.
`STATE` is the new preparation state, `ADMIN_KEY_FILE` is an existing 0600 admin
key file. No new account/API key is needed. Do not print its contents.

```bash
python3 -B "$PREDEPLOY" recheck --state "$STATE" --pinned-tool "$PINNED" \
  --candidate-profile "$PROFILE" --candidate-profile-sha256 "$PROFILE_SHA"
GALLERY_DEPLOYMENT_APPROVED=YES GALLERY_ADDITIVE_MIGRATION_APPROVED=YES \
  python3 -B "$PREDEPLOY" deploy --state "$STATE" --pinned-tool "$PINNED" \
  --candidate-profile "$PROFILE" --candidate-profile-sha256 "$PROFILE_SHA" \
  --key "$ADMIN_KEY_FILE" --approve-deployment --approve-migration
```

The existing pinned deployment saves exact Compose/.env and previous image,
pauses backgroundTask, checks paused/empty queues, then recreates **only**
`immich-server` API-only using a verified immutable runtime image ID. Health,
5.7.2 source/version, exact migration transition and unchanged PostgreSQL/Redis/ML
container IDs are required. No global Docker prune, volume recreation, NAS/mount
change or external worker change occurs. Failure with a deployment journal is
STOP: never blindly repeat deploy; use the approved rollback below.

Migration `1793600000000-AddAuthorizedAssetDeletion` is additive. Down migration
is deliberately refused: durable deletion evidence cannot be discarded. The old
unmodified image cannot boot after this addition without recognition. The
prepared API-only rollback bridge solves that compatibility requirement while
preserving tombstones/triggers. It is not a database rollback.

## 3. Per-owner/library permanent deletion approval

Every managed owner scope and external library starts disabled. Authorizing
`docice` never authorizes Anna or Lenia; authorizing one library never authorizes
another. Keep read-only mounts unchanged. Do not authorize a root with an
uncontrolled external writer, shared originals or unverified NFS identity behavior.

After deployment, inspect current library roots read-only through existing admin
API. Create **one** private 0600 JSON plan per explicitly approved scope with keys
`ownerId`, `scope` (`managed` or that owner's real library UUID), `roots` (exact
existing roots), `verifiedExclusiveRoots: true`. This attests the controlled
namespace after actual disposable NFS acceptance, not a permission bypass. Use
real verified NAS evidence; no fabricated hashes/snapshot identifiers.

```bash
# Only after separate approval for THIS owner and library.
GALLERY_LIBRARY_DELETION_APPROVED=YES python3 -B "$ARTIFACTS/tooling/authorize_library.py" \
  --state "$STATE" --plan "$LIBRARY_PLAN_FILE" --key "$ADMIN_KEY_FILE" \
  --pinned-tool "$PINNED" --candidate-profile "$PROFILE" \
  --candidate-profile-sha256 "$PROFILE_SHA" --approve-library
```

This calls the existing admin policy API. Server verifies current owner/root
membership, canonical paths, existing filesystem permissions and cross-owner
inode/path overlap. It creates no NAS API/service and changes no mount/permissions.
Actual unlink failures keep a durable receipt and are visible/retryable; retries
never authorize a replacement file. An explicitly approved disable can use the
same existing policy API with `enabled=false`; pending operations cannot override
revocation. Automatic retention is unconditionally skipped in this release.
Resuming other workers is a separate approval and does not enable retention or
library opt-ins. Do not run legacy FileDelete jobs or change queue contents.

## 4. HP-signed Android update (no rebuild)

Android CI produces a release-mode APK signed with the runner debug key. It
**cannot update** the installed HP-signed app. The existing certificate remains
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`, alias `foto`,
package `de.opennoodle.gallery`. Existing JDK 17/SDK 36 tools and original signing
files on HP are required. No key is created/exported or used in CI.

After separate merge/signing approval, integrate the exact candidate into `work`
by fast-forward only if production HEAD is still the expected baseline. Signing
refuses a dirty checkout, unexpected SHA or key/certificate. Do not merge now.
A non-fast-forward integration needs a new reviewed source/artifact binding.

```bash
# Only after approved integration and HP signing; production checkout is unchanged before then.
python3 -B "$ARTIFACTS/tooling/android_release.py" sign-existing \
  --repository /opt/gallery-fork \
  --expected-head 76bbcf708e12ee811041adcc38fd7909a7d6da15 --build-number 9 \
  --candidate-profile "$PROFILE" --candidate-profile-sha256 "$PROFILE_SHA" \
  --input-apk "$ARTIFACTS/android/app-release.apk" --authorize-production-signing
```

The script verifies APK source/hash/manifest/package/version/signature/native
libraries, re-signs unchanged payload using the existing HP key, checks alignment
and production certificate, and prints `Foto.apk` path/SHA-256. Output is below
`/opt/gallery-fork/mobile/build/release-handoff/android-5.7.2-9-76bbcf708e12/`.
Install that **Foto.apk** over build 7/8 on S23, without uninstalling or clearing
app data. Verify session/settings and package/version/certificate after install.
HP signing and physical update are operator gates, not cloud test results.

## 5. iPhone / existing SideStore route

Unsigned build 9 uses the existing macOS-15/Xcode 26.2/Flutter 3.47.2 build-only
workflow. Runner `de.opennoodle.gallery` (iOS 15), ShareExtension
`de.opennoodle.gallery.ShareExtension` (iOS 16) and Widget
`de.opennoodle.gallery.Widget` (iOS 17) are retained. App Group is
`group.de.opennoodle.gallery.share`. Technical base names are ASCII; Russian
launcher localization remains `Фото`. No paid Apple certificates or new service.

Download `ios/Photos-unsigned.ipa` from the handoff or its exact source run.
It is **not directly installable**. Keep the current Apple Personal Team and
existing SideStore bundle/App Group mapping for an update. Choose
**Keep App Extensions (Register App ID for Each Extension)**. Main-profile-only
signing is not the established separate extension-ID route.

If the existing installation uses the prepared seed, prepare with the **same**
real Personal Team ID on macOS; this preserves the original unsigned IPA and
changes only the required custom AppGroupId/ShareMedia handoff metadata:

```bash
# macOS only, using the SAME existing SideStore team/mapping.
IPA_SHA="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["ios"]["sha256"])' "$PROFILE")"
python3 "$ARTIFACTS/tooling/ios/release/prepare_sidestore.py" \
  --ipa "$ARTIFACTS/ios/Photos-unsigned.ipa" --input-sha256 "$IPA_SHA" \
  --team-id "$EXISTING_PERSONAL_TEAM_ID" --version 5.7.2 --build 9 \
  --output "$NEW_SEED_OUTPUT_DIRECTORY"
```

Use the prepared seed IPA in SideStore only where that mapping was established.
Do not invent a new mapping or remove extensions to solve a signing failure.
Retain SideStore/LocalDevVPN, Developer Mode/trust and 7-day refresh requirements.
Verify session preservation, Share Extension, Widget and App Group on the iPhone.

## 6. Smoke test, device acceptance and rollback

After approved deployment, the existing acceptance action uploads only a newly
created synthetic PNG, verifies Trash/Restore, timestamps and original bytes,
and leaves it Active. It does **not** permanently delete user media.

```bash
GALLERY_DEPLOYMENT_APPROVED=YES python3 -B "$PREDEPLOY" acceptance \
  --state "$STATE" --pinned-tool "$PINNED" --key "$ADMIN_KEY_FILE" \
  --candidate-profile "$PROFILE" --candidate-profile-sha256 "$PROFILE_SHA" --approve-deployment
```

Follow `GALLERY_BUILD9_ACCEPTANCE.md`: Android/iPhone/web, each user separately,
local-only/NAS-only/both, photo/video/Live/Motion, single/bulk/permission denial,
offline/restart/delayed sync, albums/search and original chronology. Permanent
NFS acceptance needs a separately approved **disposable-only library**, never
family originals. Validate mount semantics without granting extra permissions.

```bash
# Only after explicit rollback approval; same state/journal and private key.
GALLERY_DEPLOYMENT_APPROVED=YES python3 -B "$PREDEPLOY" rollback \
  --state "$STATE" --pinned-tool "$PINNED" --key "$ADMIN_KEY_FILE" \
  --candidate-profile "$PROFILE" --candidate-profile-sha256 "$PROFILE_SHA" --approve-deployment
```

Rollback verifies/reloads the exact saved bridge archive if necessary, restores
only the immediately previous API plus recognition markers, keeps workers off
and queue paused, preserves DB/tombstones and checks unrelated container IDs.
It cannot undo a completed NAS unlink. Database + NAS recovery and reconciliation
need a separate approved recovery procedure; never restore only SQL and claim
physical media recovered. Keep all old snapshots, backups and new receipts.

## Tooling validation boundary

Python syntax/guard tests, real classic Docker import and tamper fixtures, and
actual immutable rollback overlay creation are cloud-tested. The proof workflow
also exercises real containerd import; only its successful result establishes
that store check. Exact HP fresh-backup migration/rollback startup is performed
by `prepare`, and remains **PREPARED / NEEDS HP VALIDATION** until its PASS.
Production signing, SideStore update and physical deletion are
**PREPARED / NEEDS PHYSICAL VALIDATION**. No VAAPI/Memories setup is required.

Current reusable tools: `android_release.py`, `gallery-build-mobile.yml`,
`prepare_sidestore.py`, `server_build.sh`, `trash_predeploy.py`,
`rollback_bridge.py`, `authorize_library.py`, `gallery-trash-release-proof.yml`.
Historical build-8 evidence is retained separately; never apply its artifact
hashes or migration-equality assumptions to this new candidate.
