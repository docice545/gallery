# Historical Gallery build 9 preparation gate

Current builds and image-only updates use
[RELEASE_RUNBOOK.md](../../docs/RELEASE_RUNBOOK.md) and
[`image_release.py`](image_release.py). This document describes archived build-8/9
preparation and evidence checks. Its pinned artifacts do not certify the current
candidate, its new migration, or a hardened rollback image.

The archived build-9 application source is
`76bbcf708e12ee811041adcc38fd7909a7d6da15`, server 5.7.2/mobile 5.7.2 (9).
Its recorded production baseline was `work` at
`42790b06edc21438811e56e40c431eee37c24894`; this is historical evidence, not a
current production-state assertion.

Production `deploy`, `rollback` and `enable-workers` actions are disabled in
both repository entry points, including imported mutation functions. Use the
reviewed `image_release.py` plan/apply/rollback procedure in the runbook. It
preserves API and microservices and permits only the server image to change.
Frozen historical copies must never be used to bypass these guards. Unmodified
build 9 is not a rollback target for the current bound-root deletion schema.

For preparation/evidence reuse, `trash_predeploy.py` explicitly accepts either the
reviewed repository helper hash or the unchanged historical SHA-256-pinned helper from
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

In the archived build-9 preparation, the exact additive migration ran against that isolated restore,
followed by startup migration recognition using an API-only rollback overlay on
the exact previous image. Counts/migrations remain unchanged except for the one
addition; new policies/tombstones must be empty. That overlay is evidence for the
historical fixture only and must not be activated in production.

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

## Deployment boundary

Preparation and recheck retain their recovery and artifact identity checks.
Their successful receipts are not deployment approval. Historical candidate
preparation builds an isolated migration-recognition overlay; that workflow is
not part of a schema-compatible image-only repair and must not be run merely to
update the image. Historical overlay files and receipts remain evidence.

The new image-only helper never builds/imports images or changes queues/policies.
Its plan and default apply/rollback modes inspect existing configuration, query
the existing local PostgreSQL migration inventory read-only, and inspect packaged
guard files in isolated read-only image probes with no application workers. It
writes private local plan evidence. Actual apply/rollback require the separate
`--execute-approved` flag plus `GALLERY_DEPLOYMENT_APPROVED=YES`.
Any pending additive migration also requires `--approve-migration` and
`GALLERY_ADDITIVE_MIGRATION_APPROVED=YES`. Candidate and separately reviewed
hardened rollback images must have identical compiled migrations and deletion
guard files; capability markers alone do not establish compatibility.
API and microservices must remain enabled; actual disposable thumbnail **and**
preview processing remains an operator acceptance gate.

Library opt-ins and HP Android signing keep their separate approvals. No
family-library policy, retention permission, database/NAS restore or mount
permission change is authorized by an image update. Rollback preserves durable
journals and cannot undo physical unlink; recovery must reconcile individual
removed media rather than claiming SQL alone restores files.

Cloud guard/fixture/classic Docker tests do not establish production/NFS/iPhone
acceptance. Fresh candidate migration/rollback restore validation and production
recovery proof remain **NEEDS OPERATOR VALIDATION** until the current runbook's
isolated restore and evidence gates pass. Archived preparation PASS cannot satisfy
those gates. No production changes were executed.
