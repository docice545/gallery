# Gallery 5.7.3 (10): reviewed build and operator runbook

Production remains 5.7.2 (9), application source
`e6ab95e695f085c3016072ebff44d4ba02695cb5`. This is the next source candidate;
record its exact final commit from the validation handoff. No artifact has been
built, no key accessed and no production operation performed by this repair.
Build-8/9 artifacts and frozen profiles do not contain these fixes.

Separate approvals are required for builds, integration, production deployment,
Android signing, per-owner deletion consent, external-library deletion and
retention. The commands below are a handoff, not permission to execute them.

## 1. Build backend and clients from one reviewed source

Use a clean build checkout after build approval. Do not change the production
checkout to prepare a build. Preserve the exact repository toolchain and locks.

```bash
set -euo pipefail
: "${RELEASE_SOURCE_SHA:?Full reviewed candidate commit required}"
[[ "$RELEASE_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$(git rev-parse HEAD)" == "$RELEASE_SOURCE_SHA" ]]
[[ -z "$(git status --porcelain)" ]]
: "${BACKEND_OUTPUT:?New backend artifact directory required}"
# Read-only build metadata check; no Docker build or artifact produced.
bash scripts/release/server_build.sh "$RELEASE_SOURCE_SHA" "$BACKEND_OUTPUT" --check
# After build approval only, with an unused operator-selected output directory.
bash scripts/release/server_build.sh "$RELEASE_SOURCE_SHA" "$BACKEND_OUTPUT"
```

The build uses the committed pubspec version/build, branded committed tree,
existing Dockerfile and immutable source revision; the manifest records image ID,
archive SHA-256 and migration provenance. No production Compose file is loaded.
Its default migration baseline is the deployed build-9 application
`e6ab95e695f085c3016072ebff44d4ba02695cb5`; any different reviewed baseline must
be supplied explicitly with `MIGRATION_BASE_SHA` and reconciled with the live DB.
The historical upstream `1774548649115-AddChecksumAlgorithm.ts.ts` filename and
its existing `.ts` ledger suffix are preserved. The source exception requires
its exact reviewed SHA-256; arbitrary dotted migration names remain rejected.
Do not silently override version, source or migrate a production database to test
an image. Verify the archive checksum, config/layers/descriptors, packaged source,
architecture, version, hardened deletion capability and compiled migrations.

For iOS use the existing GitHub workflow with an **empty** version input:

```bash
# After build approval, on the exact reviewed branch; never the paid release lane.
: "${RELEASE_BRANCH:?Branch whose HEAD equals RELEASE_SOURCE_SHA}"
gh workflow run gallery-build-mobile.yml --repo docice545/gallery \
  --ref "$RELEASE_BRANCH" -f environment=development -f version= -f build_target=ios
```

Verify the run's headSha equals the recorded source. Download its existing
`ios-unsigned-archive` and `ios-unsigned-ipa` artifacts. Record actual run/artifact
IDs and IPA SHA-256; none are claimed to exist for this candidate yet. Runner,
ShareExtension and Widget remain present, base registration names ASCII and
Russian launcher name `Фото`. The unsigned IPA must report 5.7.3 (10).

Android CI validation uses the same workflow with `build_target=android`, empty
version and `android_media_pilot=true`, after the iOS run finishes to avoid shared
concurrency cancellation. CI/debug certificates cannot update the HP-signed app.

## 2. Backup, migration and rollback prerequisites

Keep the existing recovery/audit evidence; a previous receipt cannot certify a
fresh backup. Before deployment, create a new private SQL/gzip backup through the
existing read-only production dump procedure, hash it, and restore those exact
bytes in a disposable PostgreSQL instance with no production volumes/network.
Verify counts, owner/library relationships, migrations, Trash/offline states and
receipt consistency before and after candidate startup. No destructive schema
reset or mass status correction is needed.

New migration `1793700000000-BindDeletionRecovery` adds policy identities/expiry
and disables unbound legacy grants. It leaves assets and originals unchanged.
Rehearse startup and rerun against the isolated restore. The 291 offline index
records must stay Active/offline; the 12 genuine managed Trash assets stay
restorable. Non-complete old receipts without the new identity proof remain
blocked for individual review, not automatically rebound.

Unmodified build 9 is **not** a compatible rollback image: it does not recognize
the new migration and ignores signed-evidence/root binding. Before deployment
prepare a separately reviewed hardened rollback image with compatible compiled
migration inventory, and rehearse it against the same disposable restored DB.
Recognition-only patches or version-label assertions are insufficient. The image
helper inspects actual compiled capability/migrations and rejects incompatible
candidate/rollback images; lack of such an image means STOP. Do not drop the new
columns or restore an old live SQL database just to boot old code.

Recheck AssetDelete/FileDelete across every live queue state using the bounded
inventory and atomic cardinalities in the existing read-only audit. SCAN alone
is not proof of emptiness. Nonempty, unknown or incomplete inventory means STOP;
no queue clearing, retry, pause, activation or automatic retention change is
part of this workflow. Revalidate immediately before execution; empty is only
an observation at that instant. Workers must already be running normally.

## 3. Image-only deployment after explicit approval

Use `scripts/release/image_release.py` from this reviewed source, not a frozen
historical helper. It derives actual Compose topology from `immich_server` and
compares the entire effective configuration, including image-baked worker
settings. It preserves environment, mounts, networks, volumes and every other
service. API **and microservices** must be enabled; an API-only topology stops.
It never removes orphans, globally prunes Docker, resets data or modifies queues.
Keep the inpainting container even if not listed in the current Compose files.

For the already built ea51a8ac Gallery 5.7.3 (10) image, use the pinned, logged
operator handoff in [BUILD10-IMAGE-UPDATE.md](BUILD10-IMAGE-UPDATE.md).
The image helper hashes the fully resolved env-file configuration; a source-file
`compose config --hash` can differ from the actual container hash. Strict drift
checks remain enabled, and old plans require a new private state directory.
The handoff reuses atomic deletion-queue checks without altering queues.
If the old HP image has an empty baked source and stops with
`REVIEWED_ROLLBACK_SOURCE_REQUIRED`, use the separately built hardened fallback
and pinned operator workflow in [BUILD10-ROLLBACK-SOURCE.md](BUILD10-ROLLBACK-SOURCE.md).
This is a limited rollback of the new cross-owner preparation API; all deletion
guards and migrations remain intact. Never stamp a guessed source into the old image.
For the separately owner-approved six paused FileDelete jobs, use
[BUILD10-CONFIRMED-QUEUED-DELETION.md](BUILD10-CONFIRMED-QUEUED-DELETION.md).
It preserves other jobs, never resumes them, and acknowledges a selected job only
after native handler success and physical verification. Legacy original-file
jobs without durable authorization remain blocked.

```bash
set -euo pipefail
umask 077
: "${IMAGE_TOOL:?Absolute reviewed scripts/release/image_release.py path}"
: "${APPROVED_IMAGE_ID:?Verified loaded candidate config image sha256 ID}"
: "${EXPECTED_CURRENT_IMAGE_ID:?Recorded running config image sha256 ID}"
: "${RELEASE_SOURCE_SHA:?Full reviewed source commit}"
: "${APPROVED_ROLLBACK_IMAGE_ID:?Separately reviewed hardened rollback image ID}"
: "${APPROVED_ROLLBACK_SOURCE_SHA:?Full hardened rollback source commit}"
: "${APPROVED_ROLLBACK_VERSION:?Verified hardened rollback server version}"
IMAGE_STATE="$(mktemp -d /home/doctoriceadm/gallery-image-release-XXXXXXXX)"
chmod 700 "$IMAGE_STATE"
# Supply the separately validated hardened rollback target when previous image
# is unmodified build 9; use the helper's --help for its exact rollback arguments.
python3 -B "$IMAGE_TOOL" plan --sudo-docker --state "$IMAGE_STATE" \
  --image "$APPROVED_IMAGE_ID" --expected-current-image "$EXPECTED_CURRENT_IMAGE_ID" \
  --source-commit "$RELEASE_SOURCE_SHA" --server-version 5.7.3 \
  --rollback-image "$APPROVED_ROLLBACK_IMAGE_ID" \
  --rollback-source-commit "$APPROVED_ROLLBACK_SOURCE_SHA" \
  --rollback-server-version "$APPROVED_ROLLBACK_VERSION"
# Read-only preflight. No service recreation.
python3 -B "$IMAGE_TOOL" apply --sudo-docker --state "$IMAGE_STATE"
# Only AFTER separate approval for this exact source/image/state/migration.
GALLERY_DEPLOYMENT_APPROVED=YES GALLERY_ADDITIVE_MIGRATION_APPROVED=YES \
  python3 -B "$IMAGE_TOOL" apply --sudo-docker \
  --state "$IMAGE_STATE" --execute-approved --approve-migration
```

The helper records a private attempt before recreating only `immich-server` with
`up -d --no-deps --no-build --pull never`. No `--remove-orphans`, no volume deletion.
It checks health/source/version/image and all unrelated local container identities.
A failed attempt is journaled, not silently retried. Retain the original private
state and all evidence. Pending additive migrations require the separate approval
flag and environment gate shown above; neither permission authorizes deletion.
The rollback target must have the same compiled migration inventory and identical
bytes for the six guarded deletion/storage/library modules as the candidate.
An unmodified build-9 image is rejected even if its labels claim compatibility.

## 4. Install evidence and prepare managed consent separately

Follow [MANAGED-DELETION-AUTHORIZATION.md](MANAGED-DELETION-AUTHORIZATION.md) and
[the signed evidence procedure](../specs/testing/2026-10-10-trash-recovery-evidence.md).
Install only the operator public key and evidence directory as read-only binds
into the selected server. Keep the private key outside the container. This is
an explicitly reviewed preparation change, not an image-only override hidden in
step 3. Preserve all other Compose fields and services; do not alter NAS mounts.
Capture identities in the final running container, generate real signed proof,
then administrator preparation and fresh owner consent. No account/API-key change.

Every owner and external-library scope is separate. External deletion stays
blocked without separately reviewed recovery, scope approval, controlled writer
namespace, verified NFS semantics and consent. Existing writable mounts are not
permission to grant deletion. Read-only mounts remain unchanged. Automatic
retention remains skipped by the existing guard.
Use [EXTERNAL-LIBRARY-DELETION.md](EXTERNAL-LIBRARY-DELETION.md) for the existing
external worker's per-library signed preparation and explicit owner consent in
Trash. This is implemented functionality with separate authorization, not an
automatic NAS grant. Validate real NFS semantics on disposable scratch media
before authorizing family-library roots; no NFS permission change is included.

## 5. HP-signed Android update after approval

Preserve package `de.opennoodle.gallery`, alias `foto` and existing certificate:
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
Current installed versionCode 9 is replaced by 10, not by a debug-signed CI APK.
Do not generate/export keys, uninstall the app or clear its data.

After approved normal integration into `work`, use the existing HP JDK17/SDK36,
Flutter3.47.2 and existing signing files. Never run this signing gate in cloud CI:

```bash
python3 -B scripts/release/android_release.py preflight \
  --repository /opt/gallery-fork --expected-head "$RELEASE_SOURCE_SHA" --build-number 10
# ONLY after HP signing approval. Regenerates required clients/plugins/tests.
python3 -B scripts/release/android_release.py build \
  --repository /opt/gallery-fork --expected-head "$RELEASE_SOURCE_SHA" --build-number 10
python3 -B scripts/release/android_release.py postflight \
  --repository /opt/gallery-fork --expected-head "$RELEASE_SOURCE_SHA" --build-number 10
```

The script checks branch/SHA/clean source, locks/toolchain, package/version,
native libraries, manifest permissions, production certificate and SHA-256;
prints the final `Foto.apk` path under `mobile/build/release-handoff/`.
Frozen `sign-existing` profiles from build8/9 cannot be used for this candidate.
Install the verified signed APK over the existing installation; verify account,
settings, upload queue and certificate without uninstalling. No HP signing ran here.

## 6. iPhone: preserve existing SideStore installation route

Runner `de.opennoodle.gallery` minimum iOS15, ShareExtension
`de.opennoodle.gallery.ShareExtension` iOS16, Widget
`de.opennoodle.gallery.Widget` iOS17; App Group
`group.de.opennoodle.gallery.share`. No new Apple credential or signing service.
Unsigned IPA is not directly installable. Use the existing Personal Team,
SideStore and LocalDevVPN mapping. Choose **Keep App Extensions (Register App ID
for Each Extension)**, preserving all existing IDs and data.

Only when the installed app already uses a prepared seed, use its **same** team:

```bash
: "${IPA_PATH:?Actual downloaded unsigned IPA}"
: "${IPA_SHA256:?Verified unsigned IPA checksum}"
: "${EXISTING_PERSONAL_TEAM_ID:?Same established SideStore Personal Team}"
: "${NEW_SEED_OUTPUT_DIRECTORY:?Unused seed output directory}"
python3 mobile/scripts/release/prepare_sidestore.py --ipa "$IPA_PATH" \
  --input-sha256 "$IPA_SHA256" --team-id "$EXISTING_PERSONAL_TEAM_ID" \
  --version 5.7.3 --build 10 --output "$NEW_SEED_OUTPUT_DIRECTORY"
```

Retain Developer Mode/trust, extensions, App Group, ShareMedia scheme and seven-day
refresh requirements. Verify session/settings preservation, Share, Widget,
Live/Motion Photos and background synchronization on a physical iPhone. No
physical or native build PASS is claimed by this source-only repair.

## 7. Acceptance and rollback

After approved deployment confirm API and microservices are connected. A fresh
disposable upload must complete **thumbnail and preview jobs**; authenticated
image APIs return valid bytes and Android/web viewing works. Worker startup alone
is insufficient. Test single/bulk Trash/Restore chronologically, mixed scopes,
consent/revocation, interrupted retry, device permission denial, Live/Motion,
albums/search/faces, upload/sync and each user separately. Never Empty Trash of a
family account as a smoke test.

Rollback uses the same private image journal and **verified hardened** target:

```bash
# Read-only rollback preflight.
python3 -B "$IMAGE_TOOL" rollback --sudo-docker --state "$IMAGE_STATE"
# Only after rollback approval; changes only the selected service image.
GALLERY_DEPLOYMENT_APPROVED=YES python3 -B "$IMAGE_TOOL" rollback --sudo-docker \
  --state "$IMAGE_STATE" --execute-approved
```

If deployment failed before the additive migration completed, rollback must also
receive explicit migration approval (`--approve-migration` with
`GALLERY_ADDITIVE_MIGRATION_APPROVED=YES`); otherwise it stops. Rehearse both paths
against an isolated restored database before approving production execution.

Keep API/microservices and every unrelated container unchanged. Never start an
old guard against enabled new policies, drop migration evidence, replay FileDelete,
replace the live DB from an older backup or recursively purge quarantine.
Rollback does not recover removed originals; restore individually from tested
snapshots/backups after separate approval, preserving newer data and receipts.

Historical `trash_release.py`, `trash_predeploy.py`, `trash_execute.sh` and
`rollback_bridge.py` mutation paths are disabled. Their frozen evidence helpers
may still be used read-only for archive/backup validation; they are not deployment
instructions. `image_release.py` native-image probes and HP deployment, real NFS,
production signing and physical-device acceptance remain operator gates.
