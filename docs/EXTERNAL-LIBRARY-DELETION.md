# External library permanent deletion — 5.7.3 (10)

This extends the existing Immich deletion worker. It does not add a NAS service,
change NFS permissions, activate retention or authorize any production library.
No production or physical Synology test was performed during development.

## History and the actual missing link

`da4a47d0c6350b96364ee0844add553592331a4f` implemented per-owner/library deletion
policies, external original snapshots/unlink, durable tombstones, receipts and
anti-reimport checks. The preceding
`6e547a94a437d32f40cc7ca860255fd9b8f285be` guarded stale retention/deletion jobs.
`19452ecfad7b39c921829f952ebd0f268e8dcc6a` replaced path-based unlink with signed
recovery evidence, bound mount identities and private descriptor-anchored capture.
It did not remove external deletion.

External deletion was intentionally disabled without a valid owner/library policy.
The binding migration also disables unbound legacy policies. The client consent
workflow subsequently implemented for `managed` did not cover library UUIDs:
external administration could prepare/enable a policy, but there was no separate
owner-consent interface. This follow-up provides that interface and prevents an
administrator's enabled flag alone from substituting for owner consent.

## Scope, consent and execution

Each exact `(ownerId, library UUID)` has an independent policy. Managed consent
does not authorize any external library. Administrator preparation validates the
library's configured import roots, exclusive owner boundary, filesystem/mount
identity and installed signed evidence, and stores a **disabled** policy. The
admin policy API rejects `enabled:true` for both managed and external scopes.
The owner then explicitly confirms that library in Trash. Existing accounts,
session/API-key authentication and permissions remain unchanged.

For external scopes the existing `authorizedBy` field records the consenting
owner; signed preparation remains bound through its proof and root identities.
Managed policies retain their administrator preparation actor. An external grant
last enabled by a different administrator is not accepted as owner consent.
Renewing preparation clears consent; missing/expired/mismatched proof fails closed.
Revocation does not require working NFS or recovery evidence. Empty owned libraries
remain listed so permission can be revoked after Empty Trash.

The repository locks the library row through consent, intent and physical deletion.
Owner changes, library removal and import-path edits serialize with deletion, or
block a later operation. Service preflight and the worker also recheck the current
library and other-owner root boundaries. File identities/checksums, shared-original
references, mount namespace and policy/receipt locks are preserved.

Known shared originals are rejected **before** irreversible intent, leaving them
restorable in Trash. References added later are checked again before unlink.
Selective deletion and Empty Trash preflight every selected scope; a missing
scope authorization blocks the new batch rather than partially deleting approved
scopes. An I/O failure after execution begins is not an atomic batch rollback:
individual receipt states must be inspected, and only unresolved work retried.

The existing worker atomically captures an eligible original into the bound root's
private `0700` quarantine, verifies its bytes/identity and unlinks through anchored
descriptors. No unconditional legacy unlink is enabled. A directory-sync failure
blocks unlink on a resumed capture as well as the first attempt. Durability waits
finish before rehashing, so changes observed during sync cannot bypass content
verification. Lost rename/unlink
acknowledgements preserve a failed receipt for an authorized identity-checked retry;
they are not silently reported as success.

Some Synology NFS exports ignore the mode requested by `mkdir(0700)` and create
`0777`. For a newly created quarantine only, Gallery validates its ownership,
directory and mount identity, applies `FileHandle.chmod(0700)` to the opened
descriptor and rechecks the actual mode and bound namespace before capturing any
original. An existing insecure/foreign quarantine is never automatically repaired.
Failed or ineffective chmod, substitution and unsupported filesystem operations
remain failed operations with preserved bytes and receipts. Validate descriptor
chmod on a disposable export using the actual container UID and NFS mount; the
host's path-based chmod test alone does not validate the container operation.

Soft Trash and Restore do not remove NAS originals. Restore preserves asset ID,
capture dates and album membership and does not recreate local phone files. The
291 `Active + deletedAt + isOffline` index tombstones remain unchanged and outside
user Trash; no migration is added by this follow-up. Retention remains skipped.

## Administrator and owner procedure after separate approval

1. Use a separately approved isolated deployment with disposable media first.
   Preserve the healthy API **and microservices** configuration. Follow the
   [release runbook](RELEASE_RUNBOOK.md); do not deploy/build during this task.
2. Verify the exact library owner/import roots and the running container's mount
   namespace. Preserve all existing read-only mounts; a root with no authorized
   write access is ineligible. No broad permission change or privileged fallback
   is provided.
3. Follow [the existing signed-evidence procedure](../specs/testing/2026-10-10-trash-recovery-evidence.md).
   Use `--scope <exact-library-UUID>`, the same owner ID, and only that library's
   verified import roots. Supply real fresh isolated PostgreSQL restore evidence
   and photo/video snapshot exports for every covered root. Existing old recovery
   reports are not automatically fresh proof. Empty/photo-only roots remain
   blocked until a separately approved genuine recovery exercise covers both types.
4. Install only the public key and signed envelopes through the reviewed read-only
   trust-store binds. Private signing material stays outside the container. Capture
   root identities again after any container recreation/remount; do not rebind old
   interrupted receipts automatically.
5. An administrator who owns the library opens Trash → **Разрешение удаления из
   внешней библиотеки**, selects its name/UUID and prepares the installed proof.
   On web expand the same section and the selected library. For another owner,
   an administrator uses the existing admin policy endpoint with that exact owner,
   library UUID, verified roots/proof and `enabled:false`.
6. The owner signs into their existing account, selects that same library in Trash,
   chooses **Разрешить удаление из этой библиотеки** and confirms. Do this separately
   for each library/user. Enabling one library grants no other scope or retention.
7. Permanently delete only disposable selected media initially. Use Empty Trash
   only with an isolated test owner whose entire Trash is disposable. Inspect the
   existing deletion status/receipts; verify both physical absence and other-owner
   controls. Revoke via **Отозвать разрешение**, including when proof expires.

Additive endpoints (all under `/api`, using existing permissions):

| Endpoint                                          | Contract                                                                                                                                                      |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /assets/library-deletion-policy`             | Owner's non-deleted libraries, including empty ones: `scope`, optional `name`, genuine Trash `count`, `authorized`. No filesystem paths or recovery contents. |
| `GET /assets/library-deletion-policy/{UUID}`      | Owner only: `enabled`, `prepared`, `canPrepare`.                                                                                                              |
| `PUT /assets/library-deletion-preparation/{UUID}` | Admin-owned library: `{recoveryProof, verifiedExclusiveRoots:true}`; prepares disabled policy from configured import roots.                                   |
| `PUT /assets/deletion-policy`                     | Existing admin-only preparation/revocation of another owner's verified scope. `enabled:true` is rejected.                                                     |
| `PUT /assets/library-deletion-consent/{UUID}`     | Owner only: `{enabled:true/false, confirmed:true}`; exact scope, no supplied owner or arbitrary roots.                                                        |

Selective deletion, Empty Trash and receipt/status APIs retain their existing
contracts. Generated TypeScript/Dart contracts include the new endpoints. Older
clients retain Trash/Restore behavior but need the updated UI or web to grant
external consent; a failed legacy force-delete must never be treated as success.

## Validation and remaining operator gates

The follow-up uses real disposable Linux files and isolated PostgreSQL. Tests cover
external photo/video unlink, Empty Trash, offline index preservation, paired media,
Restore chronology/albums, owner/scope separation, shared originals, revoked consent,
library edits racing deletion, restart/retry, and simulated `ESTALE`, `EROFS`,
`EACCES`, `ETIMEDOUT`, lost acknowledgements and unsupported directory fsync.
Synthetic NFS mount-identity tests are not real NFS validation.

Follow-up automated results (2026-10-11; zero failures or skips in these runs):

| Check                                                              | Result                                                                      |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------- |
| Backend authorization/Trash/library/security/controller unit tests | 452 PASS / 8 files; includes the 50 filesystem and 55 signed-evidence tests |
| PostgreSQL authorized deletion/retention/Timeline suites           | 77 PASS / 3 files, real disposable DB/files                                 |
| Flutter consent/API/Trash/Restore/sync/delete suites               | 248 PASS / 11 files on Flutter 3.47.2 / Dart 3.13.2                         |
| Web consent/selection/Trash/Empty Trash suites                     | 41 PASS / 4 files                                                           |

Backend ESLint/type checking, Nest compilation (including the established alias
rewrite and migration-copy step), OpenAPI/TypeScript/Dart contract generation,
scoped Flutter analysis/formatting, web ESLint/TypeScript/Svelte diagnostics and
format checks all passed. No new database migration was introduced.

The resumed-sync mutation reproducer failed against the intermediate
`8f6253113568e8b0fd1535b8d8496be2d193094d` guard: the promise incorrectly resolved
`true`. Moving the durability wait before rehashing fixes it; the new test is
included in the 77 passing PostgreSQL tests. Build only the final branch HEAD,
not that intermediate commit. The original ancestor-symlink regression also
passes within the filesystem subset.

Earlier full-suite results and the two proven inherited backend failures are
recorded in [GALLERY_P1_HANDOFF.md](GALLERY_P1_HANDOFF.md). Those expensive full
runs were not repeated for this focused follow-up. No unrelated test was disabled.

The subsequent Synology quarantine-mode fix passes 426 backend unit tests across
8 files (including 74 filesystem guards) and 81 PostgreSQL tests across 3 files,
with no failures or skips. It adds 24 filesystem regressions and 4 PostgreSQL
cases for mode initialization, substitution, failed chmod and durable retries.
ESLint, TypeScript and formatting checks pass. Client code and database schemas
are unchanged by this fix; previous client suites were not repeated.

Before claiming Synology acceptance, verify in a separate disposable scratch
export/container with the same NFS protocol, UID/GID mapping and mount namespace:

- Real rename, directory fsync, private-quarantine UID/mode and regular-file
  identity behavior. Unsupported operations must remain failed, retaining bytes.
- No consent → originals survive; valid current proof plus owner consent → exact
  disposable selected photo/video originals and exclusive Live/Motion pair removed.
- Soft Trash → Restore preserves hashes, original timestamp/order and albums.
- Empty Trash removes only disposable eligible Trash; another owner/control file
  and active offline index records survive. Unapproved mixed scopes perform no new unlink.
- Revoke before work, interrupted request/worker, stale handles/network loss and
  restart: inspect durable receipts and captured bytes, then identity-checked retry.
- Physical S23/iPhone/web: OS denial/partial local-copy results, sync/restart/rescan,
  no resurrection, uploads/thumbnails/previews/background jobs and paired playback.

Controlled storage remains required: no hostile same-UID/root writer, NAS-side
namespace remapping or retained writable descriptor during unlink. Existing
read-only mounts cannot delete originals and are never changed by this feature.
This implementation is tested on disposable fixtures; actual Synology and physical
device acceptance are **NOT TESTED** and remain explicit operator gates.

Rollback uses only a hardened compatible image with the reviewed migration and
guard-module inventory. Preserve tombstones/receipts/quarantine and all evidence;
never downgrade to an unconditional legacy NAS unlink. Image rollback cannot
restore unlinked originals; use separately approved per-file snapshot recovery.
