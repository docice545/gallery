# CLI Live Photo retry fix — 2026-10-15

## Source and scope

Base: `3d6407da3134e345dd3b8adb8289b089c9b31074`, published as
`handoff/gallery-final-p1-cli-3d6407da3` in `docice545/gallery`.

Development branch: `fix/cli-livephoto-empty-receipt-retry-3d6407da3`.
The CLI changes for owner-scoped SSD originals, recovery proof preservation and
persisted quarantine intent are retained. The earlier Cloud implementation and
NFS recovery ZIP are not applied. No mobile, API, schema, policy, filesystem
primitive, release tooling or worker configuration changes are included.

## Confirmed defect and correction

`AssetRepository.preparePermanentDeletion()` can be called with either component
ID by the existing recovery worker. For a Live Photo, both receipts have the JPG
as `operationId`. The old error handler compared `operationId` with the incoming
asset ID. A retry through the MP4 therefore updated no receipt and left the old
`ORIGINAL_OUTSIDE_AUTHORIZED_ROOT` visible even when the current failure differed.
Policy rejection in the first preparation transaction also left stale errors.

The correction resolves the operation through the requested owner's existing
receipt and records the actual preparation error for that owner's operation.
It covers both preparation transactions, preserves `complete` / `files-removed`,
does not fabricate receipts, and adds owner predicates to the second transaction.
No deletion authorization or path admission is broadened.

Importantly, the unchanged CLI base already completes a synthetic retry of old
`failed`, `files=[]` receipts using a real child worker followed by the JPG
request. An empty `recoveryProof` is supported by that base's explicit `storage`
mode; this patch does not change that contract or relax signed-evidence checks.
The old production receipts predate the installed image. Their old error alone
does not establish that a new attempt has failed with the same root-admission
error. This patch fixes the reproduced stale-error defect, not an unobserved
production mount/type/link mismatch.

## Executed verification

Environment: Linux x64, Node 24.21.0, pnpm 11.24.0, Vitest 4.1.11.
Dependencies and lockfiles unchanged; no packages installed for this correction.

| Check | Result |
| --- | --- |
| Regression spec on unchanged CLI base, before final wrong-owner case was added | 2 PASS, 4 FAIL, 0 SKIP |
| Same six scenarios plus wrong-owner case after correction | 7 PASS, 0 FAIL, 0 SKIP |
| Existing CLI PostgreSQL/filesystem suite plus new regression spec | 89 PASS, 0 FAIL, 0 SKIP (82 existing + 7 new) |
| Five relevant unit suites | 409 PASS, 0 FAIL, 0 SKIP |
| TypeScript `tsc --noEmit -p tsconfig.json` | PASS |
| ESLint on changed TypeScript files, zero warnings | PASS |
| Prettier on changed TypeScript files | PASS |
| `git diff --check` | PASS |

New coverage: parent and child failure diagnostics, revoked consent before
hashing, wrong-owner calls, terminal/foreign/unrelated receipt preservation,
real child-worker to parent-request completion, idempotent repeat, and recovery
after a worker preparation failure. Successful deletion verifies both disposable
originals and asset rows disappear, both receipts complete, events occur once,
upload-only policy roots remain unchanged, and no original `FileDelete` bypass
is queued.

The unchanged suites include ancestor-symlink/root replacement, mount identity,
quarantine interruption and retry, NFS-error/root-squash emulation, shared files,
scope isolation and offline-index tombstone protection. They use disposable local
files; NFS behavior is emulated, not verified on a real Synology server.

The medium harness starts its own digest-pinned PostgreSQL 14 container, applies
the existing migrations and uses isolated test databases. Its existing defaults
disable `fsync`, `full_page_writes` and `synchronous_commit`; these results are
functional/transactional regression evidence, not power-loss durability proof.
No production connection, volume or original was used.

Commands, from `server/` with the existing toolchain in PATH:

```bash
pnpm --config.verify-deps-before-run=false exec vitest run \
  --config test/vitest.config.medium.mjs \
  test/medium/specs/services/authorized-deletion.spec.ts \
  test/medium/specs/services/cli-livephoto-retry.spec.ts --reporter=dot

pnpm --config.verify-deps-before-run=false exec vitest run \
  --config test/vitest.config.mjs \
  src/utils/authorized-deletion.spec.ts src/utils/deletion-recovery.spec.ts \
  src/utils/recovery-evidence.spec.ts src/services/managed-deletion.service.spec.ts \
  src/services/asset.service.spec.ts --reporter=dot

pnpm --config.verify-deps-before-run=false exec tsc --noEmit -p tsconfig.json
pnpm --config.verify-deps-before-run=false exec eslint \
  src/repositories/asset.repository.ts \
  test/medium/specs/services/cli-livephoto-retry.spec.ts --max-warnings 0
pnpm --config.verify-deps-before-run=false exec prettier --check \
  src/repositories/asset.repository.ts \
  test/medium/specs/services/cli-livephoto-retry.spec.ts
```

Original runtime preimage SHA-256 on the CLI base:
`ae8b41b8794081a5a05bcfca57ba8ebaa6fe87c8019e2e93756348407ed31750`.

Logs retained in the Cloud workspace:

| File | SHA-256 |
| --- | --- |
| `/tmp/gallery-cli-retry-baseline-final.log` | `52fb6861368ff25c49e4581ca5a7b049ba6827ca6d49f43064993e0e1d714d12` |
| `/tmp/gallery-cli-retry-final-medium.log` | `692c0985bf0dd5b017572fe160ca6470625683bb39de161a4c8c111c1aa8d5de` |
| `/tmp/gallery-cli-retry-final-unit.log` | `a4c2459315762d98d4466de1c16dfd3a6d0fc4d443d44e602ff5c030756fd41a` |

## Application and rollback boundary

Apply only to a separate source branch based on the published CLI commit. Check
the diff and `git apply --check` before applying the accompanying two-file patch;
do not apply it over unknown HP edits. It requires no database migration, policy
edit, manual receipt reset or original-file operation. The unified patch contains
only the repository change and the new spec; this report is separate.

Production rollout and any physical retry require a separate operator decision.
No image/APK/IPA was built and no production deployment was executed here. A
future server image must record the tested source revision; Android Build 12
remains unchanged. Keep API and microservices enabled, preserve existing queues,
mounts and unrelated services, and do not activate retention or clear jobs.
The existing recovery sweep may retry previously authorized persisted intents
when a server starts: review that behavior before approving rollout.

Source rollback is a normal revert of this correction. An approved image rollback
must use the recorded previous image and preserve the database and receipts.
Rollback cannot resurrect an original that an authorized deletion already
removed; retain verified backup/snapshot recovery. Do not restore the production
dump or remove existing images as part of this patch.

## Remaining operator/device gates

- Real Synology NFS and SSD execution, installed-image/source correspondence and
  production retry outcome: **NOT TESTED** by this work.
- Android Build 12 gray tile: **NOT REPRODUCED / NOT DEVICE-TESTED**. Synthetic
  tests prove the still and both originals survive preparation failure and the
  normal retry removes both records, not the rendering behavior on the phone.
- After separately approved deployment, use one newly created disposable Live
  Photo. Verify Trash, restore and explicit permanent deletion, both components,
  fresh receipt results, app restart/sync and absence of a separate gray tile.
  Do not replay historical family-photo deletions merely as a smoke test.

Verdict: the narrow server correction is regression-tested. Full production and
device readiness remains gated; no production success is claimed.
