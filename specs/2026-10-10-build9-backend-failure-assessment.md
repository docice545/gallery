# Build 9: focused assessment of the two backend unit failures

Verdict: **SAFE_TO_BEGIN_HP_PREFLIGHT**. Neither failure requires an application
fix or artifact rebuild for the approved Gallery-to-Gallery release/rollback.
This is not authorization to deploy, sign, run deletion workers or modify HP.

Application: `e6ab95e695f085c3016072ebff44d4ba02695cb5`.
Release tooling assessed: `a8b6643490d2dea12e7140b1bdad4647c099bb16`.
Unchanged production baseline: `42790b06edc21438811e56e40c431eee37c24894`.

## Same-environment reproduction

On 2026-10-10 both original failing suites were executed again, without editing
tests, exclusions, expected results or runtime code:

```bash
"$SHARED_VITEST" run --config test/vitest.config.mjs \
  src/schema/revert-to-immich.spec.ts \
  src/utils/shared-space-album-scope.guard.spec.ts --reporter=verbose
```

The command ran from each source's `server/` directory. Both used Node
**24.21.0**, Vitest **4.1.11**, the same physical resolved `server/node_modules`
directory and the unchanged unit configuration (`TZ=UTC`). No dependency
installation or lockfile changes occurred. All **910** assessed baseline inputs (`server/src`, unit config, tsconfig and
`scripts/revert-to-immich.sql`) were verified byte-for-byte against Git blobs at `42790b06`. No missing or
modified input was found. Current application build inputs still match `e6ab95e6`.

| Source | Passed | Failed | Process exit | Errors |
| --- | --- | --- | --- | --- |
| Exact baseline `42790b06` | 33 | 2 | 1 | The two failures below |
| Exact candidate application `e6ab95e6` | 33 | 2 | 1 | Identical failure names and received values |

Raw rerun log SHA-256 values (retained in the cloud workspace):

```text
baseline:  59634c5b3bb191c0a8519e24237cd7224fa693748a081923d9e69e617a853c7f
candidate: 73faa9ab3ccfe6f7b261ebef2efdf4379b38b3a89c4f2697700a1b9d1c67a8bb
```

The failed suites remain failed. The assessment does not relabel them PASS.

## Failure 1: incomplete legacy stock-Immich conversion list

Exact test:

`revert-to-immich.sql > lists every migrations-gallery migration in the step-8 kysely_migrations DELETE block`

File: `server/src/schema/revert-to-immich.spec.ts`.
Assertion: `expect(missing).toEqual([])` at candidate **line 64**, baseline
**line 61**. The exact assertion error is:

```text
AssertionError: expected [ …(3) ] to deeply equal []

- Expected
+ Received

- []
+ [
+   "1791070000000-AddStackSuppression",
+   "1791071000000-AddMemoryCandidates",
+   "1793400000000-FixMemoryCandidateSchema",
+ ]
```

The actual defect is the old, manually maintained `DELETE FROM kysely_migrations`
IN-list in `scripts/revert-to-immich.sql:439`. Those three pre-existing migration
names are omitted. This is a **real defect in legacy stock-Immich conversion
tooling**, not an environment issue or a harmless cosmetic assertion.

Its execution scope is distinct from this release. The SQL is explicitly an
irreversible conversion to vanilla Immich; it is not the normal Gallery migrator,
worker, API or build-9 rollback. No runtime/build/deploy invocation of that SQL
was found in `server/src` (excluding its spec), `server/bin`, release tooling or
the candidate backend workflows. The release rollback calls
`rollback_bridge.rollback`, not this SQL, and retains all existing migrations.

Candidate lines 61–62 of the failing test **passed** before line 64 failed: the
SQL has the deletion-journal refusal and excludes the irreversible build-9
migration from the cleanup list. The candidate SQL's first safety block at
`scripts/revert-to-immich.sql:79` raises before any DROP/DELETE when
`asset_deletion_tombstone` exists, even if its explicit data-loss token is set.
The real migration's `down()` also refuses evidence loss.

The approved rollback instead creates an immutable previous-image overlay with
only two migration-recognition files. Its `up()` and `down()` throw; it does not
apply/revert schema or discard tombstones. Workers remain disabled and changed/
nonempty queues block rollback. Real Docker overlay/import/tamper proof already
passed in [run 38038138637](https://github.com/docice545/gallery/actions/runs/38038138637).
The fresh HP backup's actual upgrade/previous-API startup remains a required
preflight gate; Python guard mocks are not claimed as that live validation.

**Decision:** not a build-9 release blocker. Stock-Immich conversion is unsupported
for this candidate and must never substitute for the documented compatible
Gallery rollback. Fixing legacy conversion is a separate task; changing the
cleanup list here could wrongly imply that dropping durable evidence is safe.

## Failure 2: multiline import falsely detected as a space query

Exact test:

`space-visibility gate guard: every space asset read has a visibility gate > src/repositories/memory.repository.ts`

File: `server/src/utils/shared-space-album-scope.guard.spec.ts`.
Assertion: `expect(orphans, ...).toEqual([])` at **line 462** on both revisions.
Exact output:

```text
AssertionError: space asset read arm(s) with no nearby visibility gate.
Add spaceVisibilityGate / visibleSpaceAssetVisibilities / AssetVisibility.Timeline
to the query, or add '<file>::<fn>' to VIS_ALLOWLIST with a reason.
src/repositories/memory.repository.ts:22 (in <module>): spaceAlbumAssetExists,: expected [ Array(1) ] to deeply equal []

- Expected
+ Received

- []
+ [
+   "src/repositories/memory.repository.ts:22 (in <module>): spaceAlbumAssetExists,",
+ ]
```

The scanner matches bare helper identifiers, then ignores only lines beginning
`import` or the single-line source match. Line 22 is in the middle of a multiline
import and matches neither exclusion. It is not a query and has no visibility
predicate because it does not read data.

A separate TypeScript **6.0.3 AST** check on the unmodified source verified:

```json
{
  "flaggedLine": 22,
  "syntaxKind": "ImportSpecifier",
  "inside": "ImportDeclaration",
  "module": "src/utils/shared-space-album-scope.js",
  "actualHelperCallLines": [368]
}
```

The real helper invocation at line 368 is inside `accessibleSearchBuilder`.
Its parent asset read requires `asset.visibility = Timeline` (line 339) and
`asset.deletedAt IS NULL` (line 340), and scopes access to the viewer's owner,
partner or space membership. The projection queries also have those predicates
(for example `search` at lines 543–544). The repository, scope helper and guard
are byte-identical between baseline and candidate; this release added no new
memory access path. No test allowlist, scanner exclusion or runtime filter was
changed to obtain this assessment.

**Decision:** a static-test false positive, not a detected hidden/trashed asset
leak. It does not change execution, authentication, asset authorization or
synchronization. The two original suites still report this failure honestly.

## Focused additional checks executed

| Check | Exact scope | Result |
| --- | --- | --- |
| Memory SQL/unit suite | `src/repositories/memory.repository.spec.ts` | **19 PASS**, exit 0 |
| Real PostgreSQL visibility | `MemoryRepository > getForOverlapReconcile > R6/R9: returns exactly the assets search returns for the same memory` | **1 PASS**, 15 deselected/skipped, exit 0 |
| Candidate rollback/recovery guards | `scripts.release.tests.test_release_candidate.CandidateGuards` | **11 PASS**, exit 0 |
| AST classification | Original line 22 versus actual helper calls | **PASS**, exit 0 |

The PostgreSQL test used a new disposable database and the real candidate
migrations. It compared search/reconcile results for visible, archived, trashed
and hidden-person fixtures; only the visible fixture was returned. It used no
HP, NAS or family media. It is a targeted behavioral test, not a claim that all
memory/security scenarios were rerun.

The 11 Python checks include real Node execution of both recognition-marker
functions (both reject), modified-config/wrong-parent rejection, exact migration
transition checks and production-network/mount namespace refusal. Some transition
checks use mocks. They do not assert an actual HP database restore has happened.

Additional raw log digests:

```text
memory units:    26b3c1d19e6a2f3274b7bee97128062c87ef46f0fc0766c53b08e17b7a41e0e9
memory PG:       60f4153c0b710ff8fef5212e3797d32dd6216e8f034e00d0ad28a0c8788d6ab8
rollback guards: a1548f8f62ceab793716663ab6a2daac1631672a338fe7f80fd2404aa4a0a3b2
```

## Release impact and next gate

| Area | Impact of these failures |
| --- | --- |
| Trash / Restore / permanent deletion | Neither failing check executes or changes these paths. Existing isolated deletion evidence remains valid. |
| External libraries / NAS originals | Neither performs filesystem operations. Policies, current permissions and explicit opt-ins remain enforced. |
| PostgreSQL integrity | Legacy conversion is unsafe/unsupported for this candidate and refuses its journal; normal migration is not this SQL. |
| Mobile sync / restart protection | No sync payload, tombstone or revision implementation changes. |
| Authentication / user isolation | Import classification has no execution or auth effect; real read predicates and per-user scope remain present. |
| Approved Gallery rollback | Uses the checked immutable API-only bridge and preserves schema/journal; stock-Immich conversion must not be used. |

Only this assessment document was added. **No backend/mobile source, migration,
release script, checksum or artifact was changed; no rebuild is required.**
Keep the existing backend, Android and unsigned iOS artifacts from `e6ab95e6` and
the manifest sealed by proof run `38038138637`.

Proceed only to the existing HP preparation: a fresh backup and exact isolated
restore/upgrade/previous-API validation, real current NAS recovery evidence,
live deletion-queue inventory, image/provenance and unchanged-topology checks.
Any STOP there still blocks deployment. Deployment, library authorizations,
worker activation, signing and physical S23/iPhone/NFS acceptance remain separate
operator gates. No production action was performed during this assessment.
