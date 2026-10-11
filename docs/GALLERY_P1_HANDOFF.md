# Gallery P1 completion handoff — 2026-10-11

Branch: `fix/build9-legacy-trash-managed-authorization`.
Starting HEAD: `dcc78926fbd89ffcf1a8f8ccc4702859a135166b`.
GitHub still had this HEAD when resuming; no newer CLI implementation was found.
All existing edits were preserved. `work` was not merged or modified.
Candidate source version: **5.7.3 (10)**; no release artifacts were built.

Completed source commits:

- `19452ecfad7b39c921829f952ebd0f268e8dcc6a`: verified grants, filesystem
  boundaries, migration and backend regressions.
- `8a0dd25fc1`: client consent/errors, translations and candidate version.

The release-tooling commit containing this handoff completes the series. Obtain
the exact final source with `git rev-parse HEAD`; do not substitute either earlier
commit when building the three release components.

## Completed implementation

1. Recovery grants require installed, read-only Ed25519-signed evidence bound to
   owner/scope, current root/mount identities, actual backup bytes and isolated
   restore receipt, snapshot/export provenance and recovered sample hashes.
   Missing/fabricated/tampered/stale/wrong-root evidence fails closed. The operator
   remains the trusted signer; signatures cannot prove a dishonest operator
   actually performed a restore. Proof covers tested samples, not every file.
2. Linux no-follow descriptor walks bind roots, ancestors, leaves and mount
   namespace. Atomic capture into a private directory precedes verified unlink.
   The durable receipt names that entry; races/interruption preserve unexpected
   bytes for verified retry or individually reviewed recovery. Root/quarantine
   boundaries and consent are checked again before destructive work.
3. Owner-root isolation checks physical mount coordinates, including visible
   nested bind aliases. It is rechecked during batch preflight and the worker's
   destructive checks. Ambiguous exports/overlay relationships fail closed.
4. Administrator preparation cannot enable managed consent. Only the owner's
   consent endpoint can enable it. Revocation remains possible when storage or
   evidence is unavailable. Selective deletion and Empty Trash preflight all
   scopes; mixed unauthorized batches create no new deletion intents.
5. Legacy deploy/rollback/worker-gating mutation paths are disabled. The reviewed
   image-only helper preserves effective Compose except the server image,
   checks image-baked worker defaults, and requires API plus microservices.
   It uses `--no-deps`, never removes orphans, and records explicit attempts.
   Pending migrations require separate approval. Rollback requires the same
   compiled migration inventory and six hardened guard modules.
6. Flutter/web consent interfaces retain explicit confirmation and revocation,
   refresh stale preparation, and explain evidence/storage failures in Russian.
   Package/bundle identities, Android signing and SideStore configuration remain.

Migration `1793700000000-BindDeletionRecovery` is additive and rerunnable. It
disables unbound old grants; it changes no assets, original files, timestamps,
owners, libraries or tombstones. The 291 offline external index records remain
outside user Trash. External deletion remains separately disabled by default;
managed consent grants no external-library rights. Retention remains skipped.

## Actual validation

| Check                                              | Result                                                               |
| -------------------------------------------------- | -------------------------------------------------------------------- |
| Full backend unit suite, stable inputs             | 6,719 PASS; 2 inherited FAIL; 1 expected failure; 12 skipped; exit 1 |
| Final affected backend files                       | 399 PASS / eight files, zero failures                                |
| Filesystem security subset                         | 50 PASS, included above                                              |
| Signed-evidence verifier subset                    | 55 PASS, included above                                              |
| PostgreSQL deletion/retention/Timeline integration | 58 PASS / three files, disposable DB/files only                      |
| Full Flutter before final localized-code additions | 4,651 PASS, zero failures, one pre-existing skipped suite            |
| Final Flutter mapping/API/widget check             | 26 PASS / two files, zero failures/skips                             |
| Final web settings/selection/Trash/Empty Trash     | 35 PASS / four files, zero failures/skips                            |
| Python release tooling                             | 266 PASS; 10 explicit opt-in Docker fixture skips / 276 total        |
| Recovery generator subset                          | 32 PASS, included in Python total                                    |
| Image-only deployment/rollback subset              | 61 PASS, mocked; included in Python total                            |
| Backend lint/typecheck/Nest compilation            | PASS; migration copy and compatibility aliases preserved             |
| Scoped client analysis/typecheck/lint/format       | PASS; Svelte zero errors/warnings                                    |
| Python/shell and embedded Node-probe syntax        | PASS                                                                 |

The full backend run fingerprinted 1,163 inputs with no changes during the run.
A later split-limit lint adjustment and PG fixture adapter correction were
rechecked by the final affected suites. The six initially failing lifecycle
fixtures lacked the newly required storage-boundary mock; they now invoke the
real validator, without weakening assertions, and all 58 PG tests pass.

Both remaining backend failures reproduce identically on immutable production
source `e6ab95e695f085c3016072ebff44d4ba02695cb5`, same Node/dependencies/config:
33 PASS / 2 FAIL / 35 tests across the same two files.
`server/src/schema/revert-to-immich.spec.ts` reports three older omissions in the
unsupported revert SQL ledger. `server/src/utils/shared-space-album-scope.guard.spec.ts`
misidentifies a multiline import in `memory.repository.ts:22` as a module-level
asset read. Neither is a new deletion regression. No test was disabled to hide it.
Database revert SQL is not the release rollback mechanism.

## Security regressions and limitations

The original ancestor-symlink attack, root replacement, parent reparenting,
public-name substitution, traversal, hardlinks, root/mount identity mismatch,
quarantine substitution, interrupted capture/retry and policy revocation are
covered. Their outside/unapproved originals survive. Managed disposable unlink,
multi-user/shared-original guards, paired media and migration rerun pass.

Mount-alias tests use actual disposable directory descriptors with synthetic
kernel mount metadata. No privileged kernel bind mount or actual NFS test ran.
Controlled storage is required: a hostile same-UID/root writer, pre-opened writable
descriptor, NAS administrator remapping or DNS/storage changes are outside the
application trust boundary. Real NFS rename/fsync/UID semantics must be verified
with disposable operator media; unsupported operations retain bytes and fail.

## Next steps — separate operator gates

Source status: **READY_FOR_BUILD**; not production/device acceptance.
Follow [RELEASE_RUNBOOK.md](RELEASE_RUNBOOK.md) after explicit build approval.
Use the exact final source SHA for all three components. Do not reuse build-9
artifacts, old frozen deployment commands or an unhardened rollback image.

Before production approval: fresh exact PG backup plus isolated restore,
genuine current snapshot/export samples, reviewed immutable candidate and hardened
rollback artifacts, isolated migration/rollback rehearsal, complete fresh queue
inventory, and unchanged service/mount/worker topology. No queue modification.
Install only the public key/evidence as reviewed read-only server binds, capture
identities in the final container namespace, prepare disabled scopes, then obtain
fresh owner consent. Recreated containers/remounts require new proof; old pending
receipts with incompatible identity require individual review, not automatic
rebinding. Empty/photo-only roots require the genuine recovery exercise described
in the evidence procedure; never invent a missing sample or provenance.

Android HP signing, SideStore signing/install, physical S23/iPhone acceptance,
thumbnail/preview job completion and all production operations remain unperformed.
External authorization and retention require their own separate approvals.
No production access, merge, deployment, signing, release build or family-media
destructive operation was performed. API keys/accounts remain unchanged.
