# Live Photo root admission — 2026-10-15

## Status: production cause confirmed; corrected backend not deployed

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

## Finding from the supplied HP report

The owner's `gallery-livephoto-roots-MVpzGAT0.txt` identifies running image
`sha256:52e08a50b507ddddf591706eed8df70c1904b47fca53d5e913146853df2a2b8b`.
The compiled repository has no `deletionRootsForTarget()` method and its
preparation method does not call that helper. Its source metadata does not match
the expected application commit. The report reconfirms the correct IMAGE/VIDEO
types, ownership, relationship and enabled upload-root policy.

Most significantly, the compiled preparation method's SHA-256 is:

`2c529dac2d226718ad9ce3788ce6ce954eeaf4a921ccc0b72a78fbcee4bf4226`.

Static TypeScript 6.0.3 transpilation of the Git source at
`f26b46059726ca3c55c63c3ce1edde7e45d8404f` produces **that exact method hash**.
The method calls, at its source line 2119:

```ts
files.push(await snapshot(path, policy!.rootIdentities));
```

Thus the installed method passes only the upload/NFS identity to both components.
For the supplied MP4 under the owner's encoded-video/SSD directory,
`snapshotOriginal()` finds no containing root and throws before opening media.
The hashing transaction rolls back, explaining why both receipts retain empty
`files` even if the JPG was hashed before the MP4 failure.

This identifies the actual old **method**, not the whole image's source commit.
Do not label the image as `f26b460597` based on one method. The report's original
`DIAGNOSTIC_STAGE_FAILED` means the collector tried to call the absent helper;
it is not an additional media deletion failure. The updated collector reports
`COMPILED_DYNAMIC_ROOTS_HELPER_MISSING` explicitly and exposes only a validated
40-hex actual source revision for subsequent provenance review.

The server correction already exists in
`a0301e2197e15760b0c8e4051e0c16f99422646b`: dynamic roots are used in preparation,
quarantine binding and execution, not just one snapshot call. Preserve its
descendants `e2aecb46bc554f6492d0b6e1b18d22c05c8d69b8` (SSD restart retry),
`c9ad4cd602bf30a2e4896a80b83552db9d2f7522` (quarantine intent) and
`4e554f355755382990e12586b339d262d679bbf1` (operation error updates).
No new weakening runtime patch or manual policy expansion is required.

The fresh committed-tree build path excludes ignored `dist` and tsbuildinfo
through `.dockerignore`, uses `git archive` in `server_build.sh`, and compiles the
server in the Dockerfile. The HP report does not reveal which build invocation
or image-selection step installed the old method. Stale local build output is
not proven to be the production build cause.

Reproducible static analysis, without executing server code or building images,
is retained in the Cloud workspace:

- `production-fingerprint.mjs`, SHA-256
  `7c1f740b8f1c869e0962268f004916e893089d342685aca249fa64ce2230e44d`;
- `production-fingerprint.txt`, SHA-256
  `4b8bc8b11aef17eb20169a8ef3b5218a846fed7c5c77d01a986e0fb0afdd34ed`.

Both are under `/workspace/gallery-livephoto-root-results-4e554f355/`.

## Preventing another export of stale compiled deletion code

The existing `server_build.sh` now derives `livePhotoDynamicDeletionRoots` from
the exact selected Git source. A half-present source implementation fails with
`SOURCE_INCOMPLETE`. If that source includes the fix, the existing isolated,
read-only, network-disabled packaged Node check requires the actual helper,
its use by preparation, and root forwarding by the snapshot/API/worker paths.
An old compiled method is rejected before `docker save`, even if its source ENV
claims the correct commit. Reviewed old source without this feature can still
build, preserving rollback build compatibility. The check never invokes deletion
methods and does not change deployment or rollback behavior.

This guard protects the normal build/export path. It does not attest or repair
an already installed image, and it is not a substitute for the disposable media
acceptance test or existing source/image/migration/rollback verification.

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

The report contains roles, safe error codes, booleans, compiled-code hashes and
the actual source revision only when it is a valid public 40-hex Git commit.
It omits original paths, filenames, user/asset IDs, credentials and raw errors.
An exit code of zero means the diagnostic completed, **not** that deletion passed.
Even `PATH_PREDICATES_PASS` does not prove filesystem deletion or production
readiness; it is the containment/canonical-path analysis of the reported inputs.

Run only the checksum-pinned command from the accompanying handoff. It downloads
the pinned tooling without checkout/reset, writes a new private script and
TXT report under `/home/doctoriceadm/`, checks syntax, and executes the collector.
No existing uncommitted files or `BUILD11_*.log` files are touched. Supply the two
asset IDs, owner ID and expected application commit from the task, not fabricated
values. The existing HP report already establishes the old-method mismatch;
repeating the inventory or testing deletion on the current image is unnecessary.

## Validation and limits

- New native StorageCore PostgreSQL/filesystem scenarios: 9 PASS, 0 FAIL/SKIP.
- Collector integration against actual isolated PostgreSQL: 3 PASS, 0 FAIL/SKIP.
  It works with nonexistent media paths, preserves receipts byte-for-byte, and
  rejects a read-write session before reading operation data.
- Collector Node tests: 19 PASS, 0 FAIL/SKIP, including explicit missing-helper
  handling and source metadata redaction/validation.
- Existing backend build-tool suite: 27 PASS, 0 FAIL/SKIP, including 7 new tests.
  They exercise the real embedded packaged check using synthetic ESM classes:
  correct classes pass, old method/missing helper/policy-only snapshot/broken
  HTTP or worker forwarding fail, and reviewed older source remains supported.
- Bash syntax and `git diff --check`: PASS. No Docker build was run.
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

No deployment is performed by this checkpoint. The required server fix is already
in the validated CLI source. After build approval, use the existing
`scripts/release/server_build.sh EXPECTED_FULL_SHA NEW_OUTPUT_DIRECTORY` from a
clean dedicated source checkout, using its exact committed HEAD. It archives
tracked files and cannot import ignored local `dist` or HP `.env` files.
Do not build from an unknown dirty HP checkout or reuse the currently running
image as the corrected artifact. Record source, image ID, archive checksum and
the compiled preparation method/helper. Source ENV alone is insufficient: verify
the compiled method has the dynamic-root call and rerun the focused disposable
Live Photo scenario against the new artifact before deployment approval.
Preserve the previous image, backups, existing mounts and all unrelated
services. Verify migration compatibility; never reset receipts or broaden policy
roots manually. Keep API and microservices enabled. Review previously authorized
pending intents before starting a new server because the normal recovery sweep
can retry them. Starting a corrected image can therefore resume physical deletion
of existing authorized intents; deployment approval must explicitly cover how
those intents and retention are gated. Do not silently pause, clear or replay
queues, disable microservices, or promise a one-pair-only production test without
that review.

After separate approval, test one newly created disposable Live Photo: verify
Trash preserves JPG/MP4, restore preserves IDs/chronology, then explicitly confirm
permanent deletion of that pair. Check both originals, both receipts, both asset
rows and mobile restart/sync, including absence of a separate gray tile. Do not
replay historical family-photo deletions as a smoke test.

This checkpoint needs no schema or data rollback. Revert its source commit if
necessary. A future approved image rollback must preserve DB/receipts and cannot
restore originals already deleted; that requires separately verified recovery.
