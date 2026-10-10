# Gallery 5.7.2 (9): verified release handoff

Application source: **`e6ab95e695f085c3016072ebff44d4ba02695cb5`**, branch
`candidate/gallery-trash-full-delete-5.7.2-build9`.
Artifact packaging/tooling source: `2825e3dd9b840c1ad1edef297326010e1b2d876f`.
Production `work` is unchanged at `42790b06edc21438811e56e40c431eee37c24894`.

Verdict: **RELEASE_READY_WITH_OPERATOR_GATES**. This means compiled artifacts
and the isolated deletion release gates passed. It does not mean production
deployment, family-library deletion, HP signing or physical-device acceptance
has occurred. Full legacy backend/web suites are not described as green.

## Immutable artifacts

All three components below contain the same application source and version
5.7.2, mobile build 9. The backend workflow uses a later tooling-only commit;
it extracts the exact application SHA and checks that application build inputs
have not changed.

| Component | Successful workflow | Downloadable artifact |
| --- | --- | --- |
| Backend | [38036956640](https://github.com/docice545/gallery/actions/runs/38036956640) | [gallery-trash-server-linux-amd64](https://github.com/docice545/gallery/actions/runs/38036956640/artifacts/11663769366) |
| Android | [38036157059](https://github.com/docice545/gallery/actions/runs/38036157059) | [android-media-pilot-validation-apk](https://github.com/docice545/gallery/actions/runs/38036157059/artifacts/11665155173) |
| iOS | [38036155443](https://github.com/docice545/gallery/actions/runs/38036155443) | [ios-unsigned-ipa](https://github.com/docice545/gallery/actions/runs/38036155443/artifacts/11663932469) |
| iOS archive | Same iOS workflow | [ios-unsigned-archive](https://github.com/docice545/gallery/actions/runs/38036155443/artifacts/11663782541) |
| Final proof/package | [38038138637](https://github.com/docice545/gallery/actions/runs/38038138637) | [gallery-trash-frozen-handoff-38038138637](https://github.com/docice545/gallery/actions/runs/38038138637/artifacts/11664701522) |

File SHA-256 values, **not** the enclosing GitHub artifact ZIP digests:

```text
backend/gallery-server-linux-amd64.tar.gz
3029d7cf7225b2e073b20e0716b3c33e4c2e9572ed4106662b546b6fe8cc9664

android/app-release.apk
479accda32b488a7bb466ed9dc8c1030f67d453de7968026df2e870706b91f81

ios/Photos-unsigned.ipa
d7fe3ed5fb823e3e2e26ccf73c650c1aec71fe09ce6b0309e8704bdb672b13ad

release-manifest.json (final containerd package)
6a9e9de192f5cefb5d81653bb78b4678e9b6500a89ff29710d202ba913ffe607
```

The final combined artifact ZIP has digest
`sha256:15082de69d6db57780ae6775f4c4c141072e84c6014edcdd5a18f58868d03105`.
Download it once and retain it privately before its 14-day artifact expiry.
The earlier classic-store proof produces a different manifest; its manifest
hash must **not** be used for this final package.

### Actual Docker identity proof

Tag: `gallery-server:trash-e6ab95e695f0`.
Config/classic image ID:
`sha256:6e65b118e8a9d352b8114f0e76ecb984f7720865856d2d7bded91f8bb66f93e7`.
Containerd manifest image ID:
`sha256:d2c378cc6e3abb10dd0cbc895d3f41b611b3189328921329913ad4d0daabd07b`.

The proof workflow successfully loaded the real archive into **both** image
stores, checked archive/config/layer content and manifest descriptors, and ran
tamper and immutable rollback-overlay fixtures. A differing store-specific ID
is accepted only when immutable content proves the identity; arbitrary digests
remain rejected. No production Docker setting was changed.

### Signing and iOS identities

The Android APK is CI-debug-signed, certificate SHA-256
`2524686bc8f160b3a438b835eb8120b19ee04cb572f4d85dc39843ed4cb08263`.
It **cannot update** the existing HP-signed S23 installation. After separate
approval, `android_release.py sign-existing` verifies and re-signs this exact
APK payload with the existing HP identity, then prints the resulting `Foto.apk`
path and its new checksum. Production certificate remains
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
No production key was accessed, generated or changed in cloud.

The IPA is **unsigned**. Xcode compilation/archive verification passed on
macOS 15, Xcode 26.2, Flutter 3.47.2. Existing identities remain:

| Target | Bundle ID | Minimum iOS | ASCII base name |
| --- | --- | --- | --- |
| Runner | `de.opennoodle.gallery` | 15 | `Foto` |
| ShareExtension | `de.opennoodle.gallery.ShareExtension` | 16 | `Foto Share` |
| Widget | `de.opennoodle.gallery.Widget` | 17 | `Widget` |

App Group remains `group.de.opennoodle.gallery.share`; Russian launcher name
remains `Фото`. Use the existing SideStore + LocalDevVPN, same Personal Team
and bundle/App Group mapping. Select **Keep App Extensions (Register App ID for
Each Extension)**. Use the existing deterministic prepared-seed script only if
that is the mapping already used by the installed app. Unsigned is not installed
until SideStore signs it. No paid release lane or new Apple credentials were used.

## What was completed and verified

The interrupted operation was the final frozen-artifact proof, after all three
builds had completed. Its existing run was resumed and verified, not duplicated.
The Docker identity fix was reused rather than reimplemented.

The candidate keeps the Immich lifecycle and existing per-user authorization.
Single/bulk server Trash precedes authorized Android/iOS local deletion; denied
or partial OS operations are reported. Owner-scoped durable local suppression
and server deletion receipts protect restart/retry/rescan paths. Restore keeps
metadata/album links and does not silently recreate deleted device files.
Permanent deletion starts disabled for every owner/library, uses existing
filesystem permissions and verified exclusive roots, and keeps failures visible
and retryable. It creates no new NAS API/service. Automatic retention is skipped.

Confirmed fixes added during resume include:

- `76bbcf708e12ee811041adcc38fd7909a7d6da15`: backend Trash excludes Active
  offline index entries; failed permanent operations stay visible. Read-only
  audit accepts absent optional derivative slots without accepting bad paths.
- `968492c09641c49f34edbcea7367fc197ef3c531`: optional sync classification,
  mobile cache schema 39, current-state validation of legacy markers and restart
  persistence distinguish index tombstones from user Trash.
- `e6ab95e695f085c3016072ebff44d4ba02695cb5`: an uncertain Trash followed by
  empty sync cannot promote an unchanged offline index entry into active Timeline.
- `2825e3dd9b840c1ad1edef297326010e1b2d876f`: bounded retries for proven registry
  rate limiting while pulling the exact fixture images; real backend smoke is
  never skipped. All mobile builds were reused for this tooling-only correction.

Evidence:

- Final Android CI: full Flutter tests/analyze, native compilation/unit checks,
  native emulator playback, APK manifest/version/native-library/signature checks
  **PASS** on the exact source. This is not physical S23 validation.
- Focused Flutter/cache checks: **894 PASS**; additional empty-sync regressions:
  **171 PASS**. Cache migration and actual SQLite restart paths are covered.
- Isolated PostgreSQL release suite: **112 PASS across seven files**; sync/Trash
  group **31 PASS**. Real concurrency, destructive disposable fixtures, restored
  chronology, owner isolation, retention, original protection and album/search
  behavior are covered.
- Final backend units: **6,609 PASS, 2 FAIL, 1 expected failure, 12 skips**. The two
  revert/scope guard failures also fail on exact production baseline `42790b06`;
  they are not hidden or counted as passed. Earlier broad PostgreSQL/web failures
  and validation limits remain recorded in `GALLERY_BUILD9_ACCEPTANCE.md`.
- Release guards: **149 total, 139 PASS, 10 SKIP**; fixture-pull/harness group
  **22 PASS**. Shell/Python syntax and runbook shell blocks passed. Real archive
  imports and rollback-overlay tests additionally passed in the proof workflow.
- iOS tooling **108 PASS**; actual native compilation/archive/IPA verification
  **PASS**. Physical PhotoKit/SideStore/background behavior remains untested.
- Backend CI: exact-source build, fresh isolated PostgreSQL migrations and HTTP
  Trash/Restore/permanent-deletion/tombstone smoke **PASS**.

## One HP preparation block — no deployment or signing

The following only downloads/verifies artifacts, reads production state, creates
a fresh backup and restores it into a disposable isolated instance. It starts no
production service and changes no production queues, NAS permissions or originals.
It uses the complete preparation block committed in the packaged runbook, with
the final successful run and manifest hash filled in. Run as `doctoriceadm`:

```bash
set -euo pipefail
umask 077
[[ "$(id -un)" == doctoriceadm ]]
HANDOFF_RUN=38038138637
EXPECTED_MANIFEST_SHA256=6a9e9de192f5cefb5d81653bb78b4678e9b6500a89ff29710d202ba913ffe607
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
assert profile['sourceCommit']=='e6ab95e695f085c3016072ebff44d4ba02695cb5'
assert (profile['serverVersion'],profile['mobileVersion'],profile['mobileBuild'])==('5.7.2','5.7.2',9)
for file in (root/'tooling').rglob('*.py'): ast.parse(file.read_text())
print('PASS exact candidate and tooling syntax')
PY_VALIDATE
DOCKER_CMD=(docker --host=unix:///var/run/docker.sock)
if ! "${DOCKER_CMD[@]}" info >/dev/null 2>&1; then
  DOCKER_CMD=(sudo -n docker --host=unix:///var/run/docker.sock)
  "${DOCKER_CMD[@]}" info >/dev/null
fi
"${DOCKER_CMD[@]}" load -i "$ARTIFACTS/backend/gallery-server-linux-amd64.tar.gz"
python3 -B "$PREDEPLOY" prepare --artifacts "$ARTIFACTS" --pinned-tool "$PINNED" \
  --candidate-profile "$PROFILE" --candidate-profile-sha256 "$PROFILE_SHA" | tee "$ARTIFACTS/preparation.txt"
STATE="$(sed -n 's/^Private state: //p' "$ARTIFACTS/preparation.txt")"
[[ "$STATE" == /home/doctoriceadm/gallery-predeploy-* && -d "$STATE" ]]
printf 'ARTIFACTS=%s\nPROFILE_SHA=%s\nSTATE=%s\n' "$ARTIFACTS" "$PROFILE_SHA" "$STATE"
```

Do not reuse an old restore receipt for this new backup. Expired NAS evidence
(24 h), expired fresh DB backup (1 h), unexpected source/image/migration,
changed production or any nonempty/unknown deletion queue is **STOP**. Refresh
only the specific expired evidence through the existing authorized recovery
process, preserving old receipts and actual snapshot provenance. Do not adjust
timestamps to obtain PASS. Queue emptiness is an atomic inventory at one instant,
not a reservation against later jobs; the separate deployment rechecks it.

## Separately approved operator sequence

The commands for each step are the committed, profile-bound commands in
`RELEASE_RUNBOOK.md`; no manual CI-log reconstruction is required.

1. Run preparation above; keep the new private state and require PASS.
2. Obtain explicit integration, additive-migration and deployment approval.
   Recheck current production/work SHA and live queues. Deploy **only** server
   API, leaving workers disabled and queues paused; verify health, version,
   migration, unchanged other containers and unrelated-service availability.
3. Obtain independent HP signing approval and integrate the exact candidate
   without overwriting other work. Run `android_release.py sign-existing` from
   the packaged tooling, then update S23 with its production-signed `Foto.apk`
   without uninstalling. Retain the newly printed production APK checksum.
4. Sign/update the existing iPhone installation using SideStore and the same
   Personal Team/mapping; retain extensions and app data. No mobile rebuild.
5. Run the disposable acceptance matrix on Android, iPhone and web for each
   user. Separate permanent-deletion scope/worker approvals are required before
   that part. Never authorize family roots from cloud fixture results alone.
6. Roll back only with approval and the same preparation/deployment journal.
   The saved immutable previous-API bridge preserves additive deletion evidence,
   keeps workers off and refuses changed/nonempty queues. It is not a schema
   downgrade, cannot undo a NAS unlink, and does not guarantee the old API has
   the new deletion contract. Database **and** NAS recovery need a separate
   approved recovery procedure if originals have actually been removed.

Permanent opt-ins, worker resumption, physical device/NFS acceptance and fresh
HP preparation are remaining gates. Default-deny library policies and disabled
automatic retention remain in force. There was no production access, signing,
deployment or merge in this development task.

## Release tooling status

| Deliverable | Status and actual boundary |
| --- | --- |
| Android `android_release.py` | **TESTED** guards/CI artifact; HP production signing/update **PREPARED / NEEDS PHYSICAL VALIDATION** |
| iOS `gallery-build-mobile.yml` / `ios_build_only.sh` | **TESTED** native compilation and unsigned archive/IPA |
| SideStore `prepare_sidestore.py` | **TESTED** tooling; installation/extensions **PREPARED / NEEDS PHYSICAL VALIDATION** |
| Server `server_build.sh` / `trash_predeploy.py` | **TESTED** isolated build/guards; deployment **PREPARED / NEEDS HP VALIDATION** |
| Rollback `rollback_bridge.py` / predeploy rollback | **TESTED** isolated immutable overlay; live rollback **PREPARED / NEEDS HP VALIDATION** |
| Memories/VAAPI setup | **NOT REQUIRED** |
| Preflight `trash_predeploy.py prepare/recheck` | **TESTED** guards; fresh actual HP restore **PREPARED / NEEDS HP VALIDATION** |
| `RELEASE_RUNBOOK.md` | **TESTED** shell syntax; operator execution remains separately gated |

The acceptance document provides PASS/FAIL/BLOCKED/NOT TESTED evidence and exact
device steps for all 15 mandatory release criteria. None is promoted to a
production/device PASS on the basis of source inspection.
