# Trash / Restore: release candidate 5.7.2 (8)

Application release SHA: **`6a558b554e26e8c0fc5bc5c99259a92e7ef26a56`**, frozen
artifact ref `build/gallery-trash-5.7.2-8-6a558b55`. Tooling branch:
`candidate/gallery-trash-5.7.2-build8`, based on the reviewed
`da8dee6f085a790561712816738c4caa1df4ffd1`. Production `work` must remain
`42790b06edc21438811e56e40c431eee37c24894` until explicit integration approval.
Use the **full release SHA from the final handoff** for every artifact and
operator command below. No merge, deployment, queue modification, HP signing
or device installation has been performed by this preparation.

## Readiness gates

The existing code validation is retained from
[the exact review validation](2026-10-09-trash-release-validation.md):
4564 Flutter tests passed (1 skipped), 627 real PostgreSQL tests passed
(12 skipped), including 17 lifecycle/concurrency tests. These suites are not
rerun locally for a version/tooling-only change. The existing Android CI lane
runs its mandatory full validation on fresh codegen before native packaging.

Two full backend failures remain visible, both reproduced on the exact earlier
baseline and in unchanged files: `revert-to-immich.spec.ts` (the upstream
switch-back SQL misses three custom migrations), and
`shared-space-album-scope.guard.spec.ts` (a textual import is counted as an
ungated read arm). Neither is changed or disabled. Image rollback below does
**not** run the defective switch-back SQL. The six pre-existing formatting
failures outside application/test scope remain documented in that validation.

Release preparation adds 49 Python Android/audit/guard tests (35 existing,
14 preparation tests), retains 108 iOS tooling tests, and verifies 7 mobile
compatibility and 6 server build-version tests. Exact CI run IDs, artifact
digests and final status are provided in the final handoff; do not substitute
old baseline artifacts. Native/physical acceptance is a separate gate.

**Production is NOT READY** until the read-only HP report, recoverable backups,
NAS snapshot evidence, all deletion consumers and the queued-job transition
plan have been reviewed. Application compilation does not authorize unlink.

## One read-only HP report

Run as `doctoriceadm`. The committed
[`hp_trash_release_audit.py`](../../scripts/diagnostics/hp_trash_release_audit.py)
creates exactly one new `0600` report at
`/home/doctoriceadm/gallery-trash-release-audit.txt`; existing files and symlinks
cause failure. It uses noninteractive Docker read access (or `sudo -n docker`)
and installed backend dependencies. It does not require SSH access from Codex.

The final handoff provides **one complete shell block** fetching the public
script at the full release SHA and checking its SHA-256 before executing it in
memory. This avoids updating the HP checkout before integration approval.
No credentials, private filenames/asset metadata, private media paths, Docker
environment dumps, SQL error details or job payloads appear in the report.
Filesystem mountpoints, image IDs, aggregate counts and anonymized examples
are the only storage/job identifiers emitted.

SQL connections enforce `default_transaction_read_only=on` and a 3-second
statement timeout. Redis commands are bounded read operations; no Queue or
Worker instance, API queue listing, Lua, retry, pause, removal or service
restart is used. The API queue-list endpoint must not be used as a substitute:
it can repair dangling jobs and does not give a complete read-only inventory.

Limits: 5000 unique live/failed jobs, 10000 paths, 45-second job scan, 90-second
container audit timeout. `truncated`, any UNKNOWN/error, unknown consumers or
unclassified paths block deployment, rather than being interpreted as no risk.
Snapshots are live/non-atomic; repeat after an **approved** pause/drain before
unpausing. Read/write flags and `access(W_OK)` are indications, not an unlink
test or proof of SMB/NFS ACL behavior. Visible `#snapshot` is not proof of a
recoverable snapshot; absence is not proof that Synology lacks snapshots.
Backup file existence is inventory only, not proof of successful restoration.
The snapshot/backup operator must confirm recovery independently.

## Version and database compatibility

- Server stays **5.7.1** via `BUILD_VERSION`, source ref `v5.7.1`, full custom
  source commit metadata. The runtime package must never report upstream 3.2.0.
- Android/iOS both **5.7.2 (8)**; build 8 exceeds the installed Android build 7.
- Mobile 5.7.2 and 5.7.1 backend compatibility is covered by the existing tests;
  the installed build 7 can still use the updated API. Routes, DTO and auth
  contracts are not changed by this release preparation.
- **No new schema migration** relative to production `42790b06`; migration files
  and schema definitions are unchanged. Mobile Drift schema is also unchanged.
  Check the real production `kysely_migration` state against image migration
  inventory before startup; an unexpected pending migration is STOP.
- Source history and both earlier review branches are preserved. After approval
  use `git merge --ff-only <FULL_RELEASE_SHA>` only if work is still the stated
  baseline. If work moved, stop, review and rebuild from the new integration SHA.
  A different merge commit is not the SHA of these artifacts.

## Backend artifact (no publishing)

The new artifact-only CI wrapper reuses the existing pinned `server/Dockerfile`,
frozen pnpm lock and branding overlay, applied in a disposable committed-tree
context. Corepack is pinned to 0.36.0 instead of `latest`. No registry publish,
ML build, production secret or production Compose access is involved.
It builds linux/amd64 for HP, exports the image, source/identity receipt and
SHA-256, then starts **fresh disposable** PostgreSQL/Redis/storage on the CI
runner. Smoke validation covers actual HTTP upload → Trash → Restore,
idempotency, dates and unchanged synthetic original bytes, plus the diagnostic
runtime. Only fixtures created by that invocation are removed.

```bash
# Isolated build machine; output directory must be new. No services deployed.
export RELEASE_SHA='<FULL_RELEASE_SHA_FROM_FINAL_HANDOFF>'
scripts/release/server_build.sh "$RELEASE_SHA" "$HOME/gallery-server-$RELEASE_SHA"
```

Workflow: `.github/workflows/gallery-trash-server-build.yml`, artifact
`gallery-trash-server-linux-amd64`; includes `gallery-server-linux-amd64.tar.gz`,
`manifest.json`, `SHA256SUMS`, image inspect and branding log. New immutable tag
`gallery-server:trash-<SHA_FIRST_12>` preserves `gallery-server:docice-work`.
No production deployment script is executed. Fresh CI migration success does
not replace a production migration-inventory or backup check.

The successful iOS build at the frozen release SHA is **not rerun**. The backend
smoke harness initially compared the version DTO to only three fields; the
actual DTO includes mandatory `prerelease: null`. That harness fix and improved
queue/backup diagnostics are tooling-only later commits. The manually dispatched
backend workflow takes `source_commit=6a558b554e26e8c0fc5bc5c99259a92e7ef26a56`;
its receipt records **both** source and tooling commits. `git archive` builds
that source SHA, and an ancestor/input-equality guard refuses an older source
if any server/mobile/Dockerfile/branding/dependency input has changed. This
preserves one exact application revision for backend, Android and iOS while
allowing a failed validation harness to be corrected. Do not substitute a later
tooling HEAD as the SHA of the already successful iOS artifact.

## Android production signing, only after approval

Existing HP checkout `/opt/gallery-fork` is the SSD bind mount of
`/mnt/hp-data/gallery-fork`; existing Pub/Gradle caches and model stay on SSD,
Docker root stays on NVMe. Do not relocate them. After the approved fast-forward
and backend queue/health gates, use the existing pipeline unchanged except its
next build guard/default:

```bash
set -euo pipefail
cd /opt/gallery-fork
export GALLERY_EXPECTED_HEAD='<FULL_RELEASE_SHA_FROM_FINAL_HANDOFF>'
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"
unset ALIAS ANDROID_KEY_PASSWORD ANDROID_STORE_PASSWORD PR_NUMBER
python3 scripts/release/android_release.py preflight --expected-head "$GALLERY_EXPECTED_HEAD" --build-number 8
python3 scripts/release/android_release.py build --expected-head "$GALLERY_EXPECTED_HEAD" --build-number 8
python3 scripts/release/android_release.py postflight --expected-head "$GALLERY_EXPECTED_HEAD" --build-number 8
```

Output: `/opt/gallery-fork/mobile/build/release-handoff/android-5.7.2-8-<SHA_FIRST_12>/Foto.apk`
and `manifest.json`. The pipeline checks package **de.opennoodle.gallery**,
version, manifest, streaming checksum and the existing production certificate
**ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18**.
It never creates/replaces a key. Do not read/export key passwords.
CI `android-media-pilot-validation-apk` is release-mode but **CI debug-signed**;
it cannot update the HP-signed S23 installation. Do not uninstall the working
app to force-install it. Final production `Foto.apk` remains **NOT SIGNED / NOT
BUILT ON HP** until the operator receives separate approval and runs the above.

## iOS: preserve the proven delivery route

Use **only** `.github/workflows/gallery-build-mobile.yml`, `build_target=ios`,
empty `version`, `environment=development`, both maintenance/pilot flags false.
macOS 15 / Xcode 26.2 / Flutter 3.47.2 and locked CocoaPods invoke existing
`mobile/scripts/ios_build_only.sh`. Artifacts: `ios-unsigned-archive` and
`ios-unsigned-ipa` (contains `Photos-unsigned.ipa`). No paid credentials/lane. The source pubspec version/build are explicitly
passed into the existing branding action so its historical build-1/tag default
cannot overwrite 5.7.2 (8).

The final handoff supplies the successful run link, exact source SHA and
5.7.2 (8) artifact. Download that artifact; **the user signs/installs it using
the existing SideStore + LocalDevVPN setup on the iPhone**. Unsigned does not
mean installable. No signing service/certificate/profile/alternative method is
added or changed. Existing preparation instructions are retained in the
[runbook](../../docs/RELEASE_RUNBOOK.md), for when the user's known SideStore
App Group/ShareMedia mapping requires a prepared seed; do not invent a new team.

Runner `de.opennoodle.gallery` (iOS 15), Share
`de.opennoodle.gallery.ShareExtension` (iOS 16), Widget
`de.opennoodle.gallery.Widget` (iOS 17), existing
`group.de.opennoodle.gallery.share` all remain. Base Apple-facing names stay
ASCII, Russian launcher name stays **Фото**. Preserve the same signing team,
SideStore mapping and bundle identity on update; never remove the installed app.
Choose **Keep App Extensions (Register App ID for Each Extension)** in the
existing SideStore route. Do not use main profile for incompatible extension
IDs and do not remove extensions. A Personal Team signing failure remains a
physical setup gate; do not silently drop capabilities or switch paid lanes.

## Approved deployment order and rollback limits

This is a plan, **not permission to run it now**. Actual Compose is
`/opt/immich/docker-compose.yml`, service `immich-server`, container
`immich_server`; repository template is not the production Compose. Only this
service may be recreated with `--no-deps`; PostgreSQL, Redis, ML, external
workers, NAS and networking must stay untouched.

1. Review HP read-only report. Confirm exact running image ID/revision, all
   deletion consumers, migration inventory, mounts and retention. UNKNOWN is STOP.
2. Create/verify private DB backup, NAS recovery snapshot, queue/payload export,
   exact Compose/config copy and previous image retention. Validate DB restore
   in isolation. No snapshot claim from merely seeing a directory.
3. With **separate queue/deployment approval**, close destructive mutations,
   pause `backgroundTask` through the supported legacy admin jobs API, drain
   active=0 and stop all old deletion consumers. Pause is not cancellation of
   active work. A running old consumer makes the transition unsafe.
4. Reconcile **every** existing AssetDelete/FileDelete against current DB and
   snapshots. New guarded AssetDelete consumer skips unknown legacy Active/
   Trashed intent; never fabricate cutoffs or expand permissions. Existing
   FileDelete is beyond the claim boundary and can unlink a NAS original.
   Current DB reference, unknown scope/history or unverified original path is
   STOP. Export exact inactive job and approve targeted cancellation **per job**.
   No automatic cancellation/retry; no clean/drain/obliterate/global Redis edits.
5. Verify backend artifact SHA and image metadata; load/build new uniquely tagged
   image. Back up actual image override and change only server image reference.
   Recreate **only** `immich-server` with `docker compose ... up -d --no-deps
   immich-server`. Never run down, remove volumes, recreate DB or globally prune.
   Keep deletion queue paused until the approved audit completes.
6. Check container healthy, `/api/server/ping`, reported 5.7.1 and source revision,
   schema unchanged, login/list/album/timeline. Compare IDs of other containers
   to backup: they must not have changed. Stop on failed validation.
7. Only after queue safety approval, allow new guarded consumers/normal mutations
   and resume queue. Then build/sign HP Android update and obtain unsigned iOS
   from the **same SHA**, sign in the user's existing SideStore flow.
8. Physical acceptance uses newly created **disposable** test media, not family
   NAS originals: single/bulk photo/video Trash/Restore, album links, capture date
   and timezone position, Live/Motion pair, offline/reconnect/restart, delayed
   response, Restore then immediate Trash. Verify no duplicates/ghosts, original
   bytes remain during ordinary Trash, session preserved and update without
   uninstall. Permanent/expiry tests belong in isolated storage only.

Rollback: close mutations, pause/drain queue, retain audit/export, restore the
**immediately previous** image/config and recreate only the server. Old deletion
workers must not consume the backlog: use the existing API-only mode
`IMMICH_WORKERS_EXCLUDE=microservices` until compatibility is separately reviewed.
Never auto-requeue an unsafe cancelled FileDelete. This image rollback does not
run schema downgrade/reset/switch-back SQL and does not recover unlinked files.
Database and NAS recovery, if actually needed, is a separate approved paired
restore; DB-only rollback cannot restore original bytes. New guards are lost on
old-worker rollback, so unpausing is a new safety decision, not automatic.

Backend deployment/queue cancellation scripts cannot be safely parameterized
with actual production IDs/config until the required report is available.
The new build/audit tooling is reusable now; deployment itself remains blocked
by evidence and approval, not by another application-code redesign.
