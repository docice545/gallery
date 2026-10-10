# Gallery build 9 pre-deployment gate

Use the exact candidate/profile and operator commands in
[RELEASE_RUNBOOK.md](../../docs/RELEASE_RUNBOOK.md). Application source is
`76bbcf708e12ee811041adcc38fd7909a7d6da15`, server 5.7.2/mobile 5.7.2 (9).
Production remains `work` at `42790b06edc21438811e56e40c431eee37c24894`.

`trash_predeploy.py` loads the unchanged SHA-256-pinned `trash_release.py` from
`565ef38c0c39f3ee896f5afd055d4d57a676d503`. Historical build-8 defaults remain
for compatibility; build 9 **requires** `--candidate-profile` and its independently
verified `--candidate-profile-sha256`. Never apply old artifact hashes/migration
assumptions to the new candidate.

## Preparation safety

`prepare` checks exact clean production checkout, healthy container identities,
5.7.1 API, completed audit, unchanged NAS provenance/sample proof (24-hour gate),
artifact bytes/source, canonical image config/ordered layers and compiled migrations.
The documented PG tag or its exact expected digest-pinned reference must resolve
locally to the running immutable Linux/amd64 identity. No arbitrary tag/digest,
pull-to-repair, broad permission change or timestamp rewriting is accepted.

A new 0700 state has a new 0600 streaming SQL/gzip backup, full gzip CRC/SHA-256,
and an exported read-only PostgreSQL snapshot. The **same exact fresh backup**
is restored in a new disposable PG with no production mounts/network/ports,
one CPU and 2 GiB memory. Counts/statuses/library references and baseline migrations
must match the dump snapshot; an old restore receipt never certifies a new backup.

For build 9 the exact additive migration runs against that isolated restore,
followed by startup migration recognition using an API-only rollback overlay on
the exact previous image. Counts/migrations remain unchanged except for the one
addition; new policies/tombstones must be empty. This is done before any deployment.

The overlay adds only two ESM migration recognition files. Exact parent ordered
layers/config, marker bytes, exported archive SHA and immutable image ID are
verified. Its up/down fail deliberately: it cannot initialize a fresh DB or drop
evidence. Saved overlay can be reloaded by exact archive SHA, never floating tag.
No production container is started/recreated during preparation.

All seven backgroundTask state counts are read atomically using read-only Redis
Lua LLEN/ZCARD/HGET, plus bounded legacy/orphan AssetDelete/FileDelete hash inventory.
SCAN alone never proves empty queues. Missing/truncated/nonempty state is STOP;
no clear, retry, pause, resume or job execution occurs during prepare/recheck.

Fresh backup must be under one hour old; NAS PASS under 24 hours. Original NAS
receipt timestamp is retained. Existing audit/backups/states are never overwritten.
Expired evidence is STOP pending separate operator revalidation. PASS is only a
preparation receipt; it does not reserve empty queues or authorize deployment.

## Separate approvals

- Deployment requires `--approve-deployment` and `GALLERY_DEPLOYMENT_APPROVED=YES`.
- Build-9 migration additionally requires `--approve-migration` and
  `GALLERY_ADDITIVE_MIGRATION_APPROVED=YES`.
- Library opt-in requires its own private owner/scope/root plan and
  `authorize_library.py --approve-library` plus
  `GALLERY_LIBRARY_DELETION_APPROVED=YES`. Uses the existing admin API, no NAS service.
- Worker activation and HP Android signing require their separate approvals.
  Automatic retention is unconditionally skipped in this candidate, even if other
  workers are separately resumed. No family-library policy is enabled by deployment.

Deploy backs up only changed Compose/.env/image, pauses/rechecks backgroundTask and
recreates only `immich-server` API-only. Health/version/source/exact additive
migration checks and unchanged PostgreSQL/Redis/ML IDs are mandatory. Any deployment
journal after failure means STOP and use approved rollback, never repeat blindly.

Rollback uses the exact previous API plus recognition markers, preserves DB
journals/triggers, keeps deletion workers off/queue paused, and checks unrelated
services. No down migration, SQL restore, NAS restore or permission change is
automatic. It cannot undo physical unlink. A later DB+NAS recovery is separately
approved and must reconcile data, not claim SQL alone recovers files.

Cloud guard/fixture/classic Docker tests do not establish production/NFS/iPhone
acceptance. Exact HP migration/rollback restore validation is **PREPARED / NEEDS
HP VALIDATION** until prepare passes. See the build-9 acceptance matrix for every
remaining operator gate. No production changes were executed.
