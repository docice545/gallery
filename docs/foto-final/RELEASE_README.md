# FOTO Build 22 — HP handoff

The source/CI checkpoint is `0719bf7042d128b09a3591f3a084af1edf2b5ae6` on
`codex/foto-build22-resume-20261029`. Use the **final published SHA supplied with
the successful Actions receipts**, including this documentation, for the HP
build. [Release gates](RELEASE_GATES.md) contains exact-SHA lookup commands;
[acceptance](FINAL_PRODUCT_ACCEPTANCE.md) separates Cloud evidence from device
and HP work. This is **NOT RELEASE READY** until those gates close.

Cloud completed source fixes and disposable tests. It did not connect to HP,
build/sign a production APK, deploy a backend, access real media or migrate a
production database. The owner performs the steps below in order; approval for
production migration/deployment is a separate decision after staging evidence.

## Preserved identity and environment

```text
Android package: de.opennoodle.gallery
versionName / versionCode: 5.7.3 / 22
required certificate SHA-256:
ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18
Flutter: 3.47.2 (bundled Dart)
JDK: 21.0.2, including javac
Node: .nvmrc (24.21.0); pnpm: package.json (11.24.0)
```

Use the existing HP key/alias `foto`; never generate a replacement or switch to
debug signing. `/opt/gallery-fork` is the existing bind mount of
`/mnt/hp-data/gallery-fork`. Keep existing SSD Gradle/Pub caches and
`/mnt/hp-data/gallery-inpainting/models/big-lama.pt`; Docker root stays on NVMe.
The [HP layout check](../../specs/testing/2026-10-04-photos-hp-build.md#фактический-ssd-layout-hp)
and [existing model check](../../specs/testing/2026-10-05-magic-eraser-hp.md#проверка-существующей-модели-и-mount)
remain applicable, but their older release numbers/build commands do not.

No second auto-stack worker is introduced. Preserve the external maintenance
process, manual suppressions and Anna's exclusion from automatic stacks;
Motion cleanup remains independent. The completed Takeout migration stays
closed. VPN, AWG, Xray, DNS, Lampac and unrelated services are outside this work.

## 1. Select source without overwriting local HP work

First finish/stop the owner's previous build session normally. Keep the existing
lock files and resource limits. Do not create another checkout or move caches.
If the checkout is dirty, preserve and review it before continuing: the following
commands intentionally stop rather than discard changes.

Set `FOTO_RELEASE_SHA` to the final 40-character SHA in the delivery and activate
the existing pinned toolchain in the normal HP build environment. These commands
run on HP by its owner, not by Cloud:

```bash
set -euo pipefail
umask 077
foto_repo=/opt/gallery-fork
foto_state=/mnt/hp-data/codex-work/foto-integration-state
foto_sha=${FOTO_RELEASE_SHA:?Set the final published 40-character SHA}
[[ "$foto_sha" =~ ^[0-9a-f]{40}$ ]]
cd "$foto_repo"
test -z "$(git status --porcelain)"
(
  flock -n 9
  git fetch origin refs/heads/codex/foto-build22-resume-20261029:refs/remotes/origin/codex/foto-build22-resume-20261029
  git cat-file -e "$foto_sha^{commit}"
  git merge-base --is-ancestor "$foto_sha" refs/remotes/origin/codex/foto-build22-resume-20261029
  git switch --detach "$foto_sha"
) 9>"$foto_state/heavy-stage.lock"
test "$(git rev-parse HEAD)" = "$foto_sha"
test -z "$(git status --porcelain)"
flutter --version
"${JAVA_HOME:?Use the existing pinned full JDK}/bin/javac" -version
node --version
pnpm --version
rg '^version: 5\.7\.3\+22$' mobile/pubspec.yaml
```

Verify the versions above and both exact-SHA workflows before building. The
checkout remains detached at the selected release; a moving branch tip is not
an artifact identity. Do not reset, clean ignored files or replace manifests.

## 2. Build and verify the APK with the existing key

Use the checked-in [serialized stage runner](../../tools/foto-automation/README.md)
with the existing state directory and HP resource envelope. It checks source
identity, retains private receipts, and refuses concurrent heavy stages. A
failed/OOM stage needs diagnosis; do not loop or delete its lock/checkpoint.

```bash
foto_runner="$foto_repo/tools/foto-automation/foto-stage-runner.py"
for foto_stage in sdk-dependencies sdk-build plugin-sdk-build workspace-link \
  openapi-dart flutter-dependencies flutter-codegen flutter-analyze; do
  python3 "$foto_runner" --repo "$foto_repo" --state "$foto_state" --resume "$foto_stage"
done
python3 "$foto_runner" --repo "$foto_repo" --state "$foto_state" --resume flutter-test \
  test/data/db/sqlite_health_test.dart \
  test/data/db/sqlite_recovery_test.dart \
  test/infrastructure/repositories/sqlite_sync_recovery_file_test.dart \
  test/presentation/widgets/memory/memory_lane_test.dart \
  test/pages/edit/editor_save_retry_test.dart \
  test/pages/edit/magic_eraser_editor_integration_test.dart
test -s mobile/android/key.properties
test -s mobile/android/key.jks
python3 "$foto_runner" --repo "$foto_repo" --state "$foto_state" --resume android-apk
foto_apk="$foto_repo/mobile/build/app/outputs/flutter-apk/app-release.apk"
test -s "$foto_apk"
apksigner verify --verbose --print-certs "$foto_apk"
aapt dump badging "$foto_apk"
sha256sum "$foto_apk"
git diff --exit-code -- mobile/pubspec.yaml mobile/pubspec.lock mobile/android/app/build.gradle
```

`android-apk` runs locked `pub get` followed by `flutter build apk --release`.
It uses the checked-in `5.7.3+22` and regenerates the release plugin registrant.
Do not use `--no-pub` for this final build or hand-edit generated registrants.
If the existing keystore is configured at another path, verify that actual
configuration locally rather than copying/replacing the key. Never print
`key.properties`, passwords or tokens into a shared log.

Require `aapt` to show exactly `de.opennoodle.gallery`, versionName `5.7.3`,
versionCode `22`, and `apksigner` to show the expected certificate. Verify the
retained Build 21 APK with the same commands and compare certificates. An
unsigned/different-certificate artifact cannot be installed as this update.
Record source SHA, tool versions, APK hash and certificate in the private release
receipt. Keep the existing Build 21 artifact.

## 3. Build a new backend image without changing the running service

Run one build inside the owner's existing bounded build environment, using
existing caches. The lock serializes this with Android stages. A Docker daemon
has its own resource behavior; retain the existing HP Docker/build limits.
The immutable tag below leaves the current production tag untouched.

```bash
foto_image="gallery-server:foto-5.7.3-build22-${foto_sha:0:12}"
cd "$foto_repo"
flock -n "$foto_state/heavy-stage.lock" docker build -f server/Dockerfile \
  --build-arg BUILD_VERSION=5.7.3 \
  --build-arg BUILD_REPOSITORY=docice545/gallery \
  --build-arg BUILD_SOURCE_REF=codex/foto-build22-resume-20261029 \
  --build-arg BUILD_SOURCE_COMMIT="$foto_sha" \
  --build-arg BUILD_IMAGE="$foto_image" \
  -t "$foto_image" .
test "$(docker run --rm --network none --entrypoint node "$foto_image" \
  -p 'JSON.parse(require("node:fs").readFileSync("/usr/src/app/server/package.json","utf8")).version')" = 5.7.3
docker image inspect --format '{{.Id}}' "$foto_image"
```

`BUILD_VERSION=5.7.3` is mandatory: changing only an image tag or
`IMMICH_VERSION` does not stamp the runtime version. This image inspection
starts no Gallery service and mounts no production volumes. The existing
Big-LaMa service/model is reused only after separate staging validation; do not
download another model or replace its deployment.

## 4. Backup and populated restore rehearsal before any production switch

The owner must select an existing private backup destination, actual database
user/name, current Compose files/overrides and current image IDs. These facts
were not read from HP by Cloud. Back up the Compose/env/secrets configuration
privately with the established backup mechanism; never upload it to GitHub.
A dump alone does not back up NAS originals, managed uploads or device SQLite.

The following creates a new backup directory and reads PostgreSQL. It does not
run migrations. `FOTO_BACKUP_ROOT` must already exist on the approved backup
storage; `FOTO_DB_USER`/`FOTO_DB_NAME` must match the existing deployment.

```bash
: "${FOTO_BACKUP_ROOT:?Existing approved backup directory}"
: "${FOTO_DB_USER:?Existing PostgreSQL backup role}"
: "${FOTO_DB_NAME:?Existing Gallery database name}"
foto_backup=$(mktemp -d "$FOTO_BACKUP_ROOT/foto-build22-$(date +%Y%m%dT%H%M%S).XXXXXX")
docker inspect --format '{{.Image}}' immich_server > "$foto_backup/previous-server-image.txt"
docker inspect --format '{{.Image}}' immich_postgres > "$foto_backup/postgres-image.txt"
docker exec immich_postgres pg_dump -U "$FOTO_DB_USER" -d "$FOTO_DB_NAME" \
  --format=custom > "$foto_backup/gallery.dump"
docker exec immich_postgres pg_dumpall -U "$FOTO_DB_USER" --globals-only \
  > "$foto_backup/postgres-globals.sql"
test -s "$foto_backup/gallery.dump"
sha256sum "$foto_backup/gallery.dump" "$foto_backup/postgres-globals.sql" \
  > "$foto_backup/SHA256SUMS"
```

Restore into a **new isolated staging database**, using the same PostgreSQL
major version, extensions and roles as the existing service. The stage must
have no production storage or credentials. Set `FOTO_RESTORE_CONTAINER` only
to that disposable container, created by the owner with label
`foto.build22.disposable=true`; the check below refuses the production container.

```bash
: "${FOTO_RESTORE_CONTAINER:?New isolated staging PostgreSQL container}"
test "$FOTO_RESTORE_CONTAINER" != immich_postgres
test "$(docker inspect --format '{{index .Config.Labels "foto.build22.disposable"}}' \
  "$FOTO_RESTORE_CONTAINER")" = true
docker exec -i "$FOTO_RESTORE_CONTAINER" pg_restore --list \
  < "$foto_backup/gallery.dump" > "$foto_backup/restore-list.txt"
docker exec "$FOTO_RESTORE_CONTAINER" createdb -U postgres foto_build22_restore
docker exec -i "$FOTO_RESTORE_CONTAINER" pg_restore -U postgres \
  --dbname=foto_build22_restore --no-owner --no-privileges --exit-on-error \
  < "$foto_backup/gallery.dump"
```

The last restore checks data/schema restoration with staging ownership. Rehearse
actual role/ACL restoration separately from the private globals backup. Then
start the candidate backend **against the staging clone only**, capture startup
migration logs, and compare users/assets/albums/stacks/pending deletion records,
counts and representative checksums before/after. Verify login, sync cursors,
upload/download, Live Photo pairing, Trash/restore, owner boundaries and Magic
Eraser save-copy with synthetic media. No production smoke script should seed,
delete or empty real libraries.

Synology acceptance requires approved staging copies/read-only originals:
NFS permissions, disconnect/reconnect, sidecars, external-library protection and
10/100/500/1000 synthetic Trash batches. Do not repeat the completed Anna
migration or apply duplicate deletion from a read-only inventory.

## 5. Owner-approved migration and server-only update

**Starting the new server on production PostgreSQL can automatically migrate
it. Approval must precede that start**, even though this continuation adds no
server migration. The populated-upgrade rehearsal, backup restore and rollback
plan must already have passed. Do not run `schema:reset`, manual
`migrations:revert` or the fresh-database CLI migration command on HP production.

During the agreed maintenance window, quiesce only Gallery writers and its
existing external maintenance process; take a final coherent PostgreSQL backup
plus the matching managed-storage/NAS snapshot. Record precisely which Gallery
services/timer were active so they can be resumed afterward. Do not stop any
VPN/DNS/AWG/Xray/Lampac service or use `compose down`.

Use the **existing** Compose project and every active override. The array below
shows the documented base; include any actual owner-configured overrides before
proceeding. Save the resolved configuration privately for review (it may contain
secrets), and confirm that only `immich-server.image` will change.

```bash
foto_compose=(docker compose --project-directory /opt/immich -f /opt/immich/docker-compose.yml)
# Include existing overrides in foto_compose if the deployed project uses them.
foto_override="$foto_backup/build22-image.override.yml"
printf 'services:\n  immich-server:\n    image: %s\n' "$foto_image" > "$foto_override"
"${foto_compose[@]}" -f "$foto_override" config --quiet
# Run the next command only after the separate production/migration approval.
"${foto_compose[@]}" -f "$foto_override" up -d --no-deps --no-build --pull never immich-server
docker inspect --format '{{.State.Status}} {{.State.Health.Status}} {{.Image}}' immich_server
test "$(docker inspect --format '{{.Image}}' immich_server)" = \
  "$(docker image inspect --format '{{.Id}}' "$foto_image")"
```

Check API health/version `5.7.3`, migration logs, existing-account login and
read-only library counts before enabling writes. Confirm unchanged image/container
identities for PostgreSQL, Redis, ML and unrelated services. Resume only the
previously active Gallery writers/maintenance after acceptance. Retain the
immutable candidate and previous image IDs; do not prune rollback artifacts.

## 6. Samsung update and rollback boundaries

First use a synthetic account on an approved test device/profile. Confirm its
installed Build 21 identity/certificate and a tested way to preserve/restore
app data, including SQLite, WAL/SHM and pending uploads/deletions. A server dump
and an old APK do not back up phone state. If the installed app's data cannot be
safely backed up/restored, production-device upgrade remains open.

Only after signing and backup checks:

```bash
: "${FOTO_TEST_DEVICE_SERIAL:?Approved Samsung test device}"
adb -s "$FOTO_TEST_DEVICE_SERIAL" install -r "$foto_apk"
adb -s "$FOTO_TEST_DEVICE_SERIAL" shell dumpsys package de.opennoodle.gallery \
  | rg 'versionCode=|versionName='
```

Never uninstall, clear app data or use a forced downgrade to bypass an update
failure. Verify accounts/settings/albums/pending work, cold restart, offline
thumbnails, portrait Memories lane, editor/history/save-copy, local/remote Live
Photo, Places, Trash/restore, stacks and owner isolation. Exercise Shizuku
allow/deny/revoke/undo/read-back, system Photo Picker and Samsung Gallery,
including account/Android-user switching and revoked server access.

Rollback must match the change actually made:

- Before any schema/data change, the retained previous server image can be
  selected with the same server-only override procedure, provided its database
  compatibility is verified.
- After migrations or writes, do not merely start an older image on the new
  schema. Stop only Gallery writers, preserve the failed state for diagnosis,
  restore the verified pre-upgrade backup into a separate recovery database and
  pair it with the matching storage snapshot. Verify counts/ownership/media and
  the old image there before an owner-approved switch. Never restore over the
  only live database or delete originals to make counts match.
- Android generally refuses Build 22 → 21 in-place downgrade. Keep phone state
  intact and use a corrective release with a higher versionCode and the same
  key, or the previously rehearsed owner recovery procedure. Do not promise
  `adb install -d` or uninstall/reinstall as a data-preserving rollback.

Record the final source SHA, Actions URLs, APK/image hashes, backup/restore
receipt, device results and the owner's rollout decision. Until those HP/device
results exist, this handoff is validated source for owner testing, not approval
to publish a production release.
