# Stage 1: final pre-deployment gate

Application/artifacts remain frozen at
`6a558b554e26e8c0fc5bc5c99259a92e7ef26a56` (server 5.7.1, mobile 5.7.2 build 8).
Production checkout remains `work` at
`42790b06edc21438811e56e40c431eee37c24894`. This tooling-only branch neither merges
that checkout nor rebuilds any artifact.

`trash_predeploy.py` loads the **unchanged, SHA-256-pinned** `trash_release.py`
from `565ef38c0c39f3ee896f5afd055d4d57a676d503`. Its default action is preparation;
deployment and rollback require both an explicit CLI flag and the existing
`GALLERY_DEPLOYMENT_APPROVED=YES` gate. No retention-enable or signing action is
exposed by this wrapper.

## Operator inputs and requirements

Run as `doctoriceadm`, with existing Docker access (or existing passwordless
`sudo -n docker`), Python 3.11+, local Docker socket, a quiet resource window,
at least 3 GiB available RAM and 8 GiB free Docker disk. Nothing installs packages
or changes sudo/group policy. The prior PostgreSQL image must already be cached.
Local staging additionally requires `max(2 × database size, 2 GiB)` free before
dumping, and `1.2 × previous server image size + 1 GiB` for rollback both before
and after backup/restore. No automatic disk cleanup is attempted.

The verified HP artifact directory is
`/home/doctoriceadm/gallery-trash-frozen-artifacts`, containing the already
downloaded/extracted frozen artifacts in this layout. Do not download or rebuild them again:

```text
ARTIFACTS/backend/manifest.json
ARTIFACTS/backend/gallery-server-linux-amd64.tar.gz
ARTIFACTS/android/app-release.apk
ARTIFACTS/ios/Photos-unsigned.ipa
```

Pinned manifest/checksums identify backend run 37953392247, Android run 37944044747
and iOS run 37936380827. The Android APK is CI-signed; the IPA is unsigned. No
production signing or device installation occurs here.

Existing default paths, all preserved:

- Tool: `/home/doctoriceadm/gallery-trash-release-tooling-565ef38/trash_release.py`
- Audit: `/home/doctoriceadm/gallery-trash-release-audit-20261009T155251367898Z-8d189795a83d.txt`
- NAS PASS: `/home/doctoriceadm/gallery-nas-recovery-sau5r5go`
- Earlier PG PASS: `/home/doctoriceadm/gallery-recovery-hum85h39`

PostgreSQL may use exactly the documented tag or that tag pinned to
`sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23`.
In either case, local `docker image inspect` must resolve the pinned reference
to the running immutable image ID, with the expected repository digest and
Linux/amd64 platform. No pull/tag/load is attempted to repair missing identity.
The manifest digest is not compared directly to the image config ID; they are
different identities. Approved audit/restore receipts still require exact
immutable ID equality, and container/user/database checks are unchanged.

Do not edit/delete/reuse `/home/doctoriceadm/gallery-predeploy-klailu49`.
Another `prepare` always creates a new private state directory. It does not use
the failed state as recovery evidence.

The NAS report, provenance, sample hashes, receipt and scope must agree. NAS samples
are **not** exported/read/hashed again. Its original verification timestamp is
preserved. The pinned 24-hour NAS gate remains in effect; expiry is STOP, never a
silently refreshed timestamp. An expired receipt requires a separately agreed
revalidation, not automatically repeating the recovery.

## Preparation (no production mutation)

Download `scripts/release/trash_predeploy.py` from the full tooling commit and
verify its SHA-256 as supplied in the release handoff. Run `python3 -B ... --help`
or syntax-check without executing before using it. The copy-paste handoff provides
the exact pinned download and checksum; avoid a moving branch URL.

```bash
python3 -B "$PREDEPLOY_SCRIPT" prepare --artifacts "$ARTIFACTS"
```

Preparation automatically creates one new 0700 local directory
`/home/doctoriceadm/gallery-predeploy-*`; all backup/evidence/log files are 0600.
Existing root-owned `/mnt/hp-data/immich/library/backups` is not written, chmodded
or read for credentials. No existing evidence or backup is overwritten.

1. Verify clean production checkout, all four healthy container identities, API
   version/ping, completed audit, NAS scope/provenance, frozen mobile checksums,
   backend manifest/image config digest and compiled migrations directly in the
   image archive. No backend image is imported during preparation.
2. Verify the current immutable server image, actual Compose files and local disk
   space needed for rollback. Configuration hashes are kept private. No image,
   Compose file, mount or production volume is changed.
3. Connect inside the existing PostgreSQL container as OS/database `postgres`, DB
   `immich`, via its Unix socket with `--no-password`. Authentication failure is
   STOP; no password, env dump or credential extraction is attempted.
4. Hold a read-only repeatable-read exported snapshot; read counts/migration names
   and make the SQL dump using **that same snapshot**. Stream gzip to a newly
   created private local file, verify full gzip CRC, SHA-256 and available disk.
   A failed dump retains only a `.partial` and private error log, never a PASS.
5. Use the pinned isolated restore: current immutable PG image, `--network none`,
   no ports, no production mounts, one CPU/2 GiB limit. Restore the **new exact**
   backup in a SQL transaction. Compare asset/status/library counts and exact
   migration names against the dump snapshot; check dangling library references.
   Only the unique disposable container and its own anonymous volume are removed.
   A failed cleanup or mismatch cannot issue a fresh restore PASS.
6. Read all seven backgroundTask state cardinalities together in one **read-only
   Redis Lua invocation** (`LLEN`, `ZCARD`, `HGET`). Supplement with a bounded
   `SCAN`/`TYPE`/`HGET`/`ZSCORE` inventory for non-completed AssetDelete/FileDelete
   job hashes, then another atomic state read. SCAN alone never establishes empty
   queues. Nonempty, unknown, truncated or orphan/legacy deletion state is STOP.
   No jobs are executed, retried, paused, resumed, cleared or cancelled.

Successful output includes `PASS`, the private state directory and
`predeploy-report.json`. `predeploy-context.json`, `fresh-backup.json`,
`fresh-restore-verified.json` and the **new** `backup-verified.json` bind that exact
backup to its new restore. Earlier PG evidence is retained only as lineage;
it never validates the new backup. Input evidence and production container IDs
are checked unchanged.

**PASS is preparation only.** Queues were empty at the recorded instant, not
reserved or continuously empty. Backup must still be less than one hour old at
deployment; NAS evidence less than 24 hours old. Expiry requires fresh preparation
(new directory, new backup, new restore) unless only the unchanged NAS receipt
requires its separate operator revalidation. Never edit receipts to bypass this.

Failures emit one sanitized `STOP` and save `predeploy-stop.json` in the new state.
Private dump/restore logs are for local inspection; do not upload them unredacted.
If a prerequisite fails, retain the state; do not rerun preparation into it.

## Separate approved deployment procedure — DO NOT RUN NOW

After the owner reviews preparation PASS and explicitly approves backend
deployment, set `STATE` to the printed private directory, retain the verified
`PREDEPLOY_SCRIPT`, and supply an existing private 0600 admin API-key file in
`ADMIN_KEY_FILE`. Never paste its contents into commands or reports.

```bash
# Только после отдельного разрешения владельца на backend deployment.
python3 -B "$PREDEPLOY_SCRIPT" recheck --state "$STATE"
GALLERY_DEPLOYMENT_APPROVED=YES python3 -B "$PREDEPLOY_SCRIPT" deploy \
  --state "$STATE" --key "$ADMIN_KEY_FILE" --approve-deployment
```

`deploy` performs the same fresh recheck again, imports only the frozen backend
image, delegates to pinned tooling, preserves exact Compose/.env backups and the
previous immutable image/archive, and pauses backgroundTask through its native API.
It **atomically** rechecks paused/empty queues before recreating only
`immich-server` with API workers; unrelated PostgreSQL/Redis/ML IDs must remain
unchanged. It verifies health, API version/source and migration equality.
Any nonempty queue is STOP; there is no automatic draining, retry or job cleanup.

Deletion/retention workers remain disabled and the queue paused. No destructive
migration is authorized: exact migration equality is mandatory. The external
AI/auto-stack processes and unrelated HP services are untouched. Preparation
does not execute this phase or authorize it.

Acceptance uses only newly uploaded synthetic test media through the pinned
`trash_execute.sh acceptance` action, after its own production approval. Native
S23/iPhone checks use exclusively disposable media, verify chronological
Trash/Restore, album membership, restart/offline/delayed sync, Live/Motion pairs.
Do not test permanent deletion on real media. Worker activation and Android
production signing retain their **separate** approval gates in pinned tooling;
they are not part of this execution block. iOS remains SideStore signing of the
existing unsigned IPA, with no paid signing service.

## Approved rollback

```bash
# Только после явного разрешения на rollback.
GALLERY_DEPLOYMENT_APPROVED=YES python3 -B "$PREDEPLOY_SCRIPT" rollback \
  --state "$STATE" --key "$ADMIN_KEY_FILE" --approve-deployment
```

Pinned journal/config/image guards apply; atomic queue guards remain installed.
Only the previous server image is restored, still **API-only**; deletion workers
stay disabled and the queue paused. Other container identities must remain
unchanged. No production database, backup or NAS snapshot is automatically restored.
Restoring the old binary cannot undo physical deletions or DB writes made after
deployment, and must not resume the old unsafe retention implementation. A later
data recovery or retention resumption requires separate explicit approval.

## Validation boundary

New tests exercise synthetic evidence/checksum/approval guards, gzip backup failure,
an actual isolated PostgreSQL snapshot/dump/restore with concurrent writes to the
**test** DB, restore-count mismatch cleanup and actual isolated Redis cardinalities.
They use unique local cloud containers, no HP/NAS data. Pinned existing rollback
fixture tests cover recreation of only the disposable Compose server and retention
of its unrelated service. Full application suites/artifact builds are not repeated.
End-to-end execution on the operator's HP remains **NEEDS HP VALIDATION** until
this block is run and its sanitized PASS/STOP is reviewed.
