# Live Photo root admission — 2026-10-15

## Status: BLOCKED, no speculative deletion patch

Application base: `4e554f355755382990e12586b339d262d679bbf1`.
Branch: `fix/livephoto-original-root-admission-4e554f355`.

This checkpoint adds focused tests and a read-only collector. It does **not**
change server runtime, mobile, deletion policy, migrations, workers or deployment
configuration. It is not a new production release candidate. No HP connection,
production deletion, rebuild, queue replay or deployment was performed.

The supplied production facts are accepted: still type `IMAGE`, motion type
`VIDEO`, correct exclusive same-owner/library relationship, enabled `storage`
policy whose sole root and identity path are the owner's upload directory.
The policy must not acquire a broad `/data` or encoded-video root. The existing
helper admits the owner's encoded-video directory only for the linked motion
component during the operation.

## What the code and executed tests establish

There are exactly two `ORIGINAL_OUTSIDE_AUTHORIZED_ROOT` throw sites:

- `server/src/utils/authorized-deletion.ts:392`, `snapshotOriginal()`: none of
  the supplied root identity paths contains the requested file.
- `server/src/utils/authorized-deletion.ts:313`, `openParent()`: path is not
  absolute/canonical, is outside the selected root, or contains the reserved
  quarantine component.

The supplied canonical upload and encoded-video paths pass these predicates
with their respective roots. Mount, device, inode and symlink failures have
different error codes; there is no evidence to weaken those checks.

`preparePermanentDeletion()` recalculates roots for every empty receipt,
including failed retries. It passes the upload policy roots to the JPG and
upload plus the dynamically collected owner encoded root to the linked MP4.
The HTTP and worker callbacks in this source forward those roots unchanged.

The new PostgreSQL/filesystem spec uses **real StorageCore folder methods**, not
the path mocks of the previous regression. A native child-worker then parent
request retry completes both disposable originals and records. Negative cases
cover wrong type, owner, library, shared companion, another owner's encoded
directory, symlink and a JPG identity-path mismatch. This source does not
reproduce the reported failure under all supplied valid inputs.

Therefore the exact production cause is **not established**. A runtime change
that merely widens roots would be unjustified. The missing evidence is the
per-component root result and code identity of the installed image, not another
mount/permissions/existence audit.

## Targeted HP collector

`scripts/diagnostics/livephoto_deletion_roots.mjs` runs in a **new Node process**
inside the existing server. It imports the installed compiled classes, computes
the same per-component roots and reports path predicate results. It records
module/method hashes and whether the HTTP/worker methods forward roots. Binding
and text markers are diagnostic indicators, not an attestation that the whole
image is the expected commit.

It uses one repeatable-read, explicitly read-only PostgreSQL transaction,
checks both session and transaction read-only flags, and disables query logging.
Its own inventory queries have small LIMITs and at most eight paths are analyzed.
The existing helper's parent query is relationship-filtered, with a three-second
statement timeout; it does not have a row-count LIMIT. A 25-second watchdog bounds
the separate CLI process during ordinary interruptible execution.

The collector never calls `preparePermanentDeletion()`, `snapshotOriginal()`,
`unlinkOriginal()`, `verifyBoundPolicy()`, application bootstrap or a job handler.
It never patches filesystem APIs or hashes/opens media. Root identity collection
opens directories read-only. Only the new process's StorageCore location is set;
the running API/microservices are unchanged. No Redis connection is created.

The report contains roles, safe error codes, booleans and compiled-code hashes.
It omits original paths, filenames, user/asset IDs, credentials and raw errors.
An exit code of zero means the diagnostic completed, **not** that deletion passed.
Even `PATH_PREDICATES_PASS` does not prove filesystem deletion or production
readiness; it is the containment/canonical-path analysis of the reported inputs.

Run only the checksum-pinned command from the accompanying handoff. It fetches
tooling into Git objects without checkout/reset, writes a new private script and
TXT report under `/home/doctoriceadm/`, checks syntax, and executes the collector.
No existing uncommitted files or `BUILD11_*.log` files are touched. Supply the two
asset IDs, owner ID and expected application commit from the task, not fabricated
values. Return that sanitized report before attempting a runtime correction.

## Validation and limits

- New native StorageCore PostgreSQL/filesystem scenarios: 9 PASS, 0 FAIL/SKIP.
- Collector integration against actual isolated PostgreSQL: 3 PASS, 0 FAIL/SKIP.
  It works with nonexistent media paths, preserves receipts byte-for-byte, and
  rejects a read-write session before reading operation data.
- Collector Node tests: 17 PASS, 0 FAIL/SKIP.
- TypeScript, scoped ESLint, formatting, Node syntax: PASS.
- Previous 409 unit / 89 medium results on unchanged application source are
  retained, not rerun. See `CLI_LIVEPHOTO_RETRY_FIX.md`.

Development used Node 24.21.0, pnpm 11.24.0, Vitest 4.1.11 and the existing
digest-pinned PostgreSQL 14 testcontainer. New destructive tests use disposable
local files. They do not emulate a real Synology server or separate physical
NFS/SSD devices. The existing medium harness has fsync/full-page-writes/
synchronous-commit disabled; no power-loss durability claim is made.

The first new test attempt exposed harness initialization errors: mock factories
reset the global media location to `/data`; the standalone diagnostic test also
initially assumed storage had bootstrapped. Those fixtures were corrected without
altering assertions, existing tests or runtime. Initial logs are preserved along
with final logs under `/workspace/gallery-livephoto-root-results-4e554f355/`.

Commands from `server/` with the existing toolchain in PATH:

```bash
pnpm --config.verify-deps-before-run=false exec vitest run \
  --config test/vitest.config.medium.mjs \
  test/medium/specs/services/livephoto-root-admission.spec.ts --reporter=verbose
pnpm --config.verify-deps-before-run=false exec vitest run \
  --config test/vitest.config.medium.mjs \
  test/medium/specs/services/livephoto-root-diagnostic.spec.ts --reporter=verbose
node --test ../scripts/diagnostics/tests/livephoto_deletion_roots.test.mjs
pnpm --config.verify-deps-before-run=false exec tsc --noEmit -p tsconfig.json
pnpm --config.verify-deps-before-run=false exec eslint \
  test/medium/specs/services/livephoto-root-admission.spec.ts \
  test/medium/specs/services/livephoto-root-diagnostic.spec.ts --max-warnings 0
```

## Future deployment and one-Live-Photo acceptance gate

No deployment is needed for this diagnostic checkpoint. After the actual failure
is identified, require a separate minimal runtime commit, a failing-before /
passing-after regression, a source-pinned backend build and explicit deployment
approval. Preserve the previous image, backups, existing mounts and all unrelated
services. Verify migration compatibility; never reset receipts or broaden policy
roots manually. Keep API and microservices enabled. Review previously authorized
pending intents before starting a new server because the normal recovery sweep
can retry them.

After separate approval, test one newly created disposable Live Photo: verify
Trash preserves JPG/MP4, restore preserves IDs/chronology, then explicitly confirm
permanent deletion of that pair. Check both originals, both receipts, both asset
rows and mobile restart/sync, including absence of a separate gray tile. Do not
replay historical family-photo deletions as a smoke test.

This checkpoint needs no schema or data rollback. Revert its source commit if
necessary. A future approved image rollback must preserve DB/receipts and cannot
restore originals already deleted; that requires separately verified recovery.
