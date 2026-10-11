# Managed deletion authorization — 5.7.3 (10)

This repair continues the build-9 consent UI and existing Immich deletion worker.
Build-9 artifacts do not contain it. No release artifact or production deployment
is produced by this development task.

## Preparation and owner consent

On mobile open Trash → ⋮ → **Разрешение окончательного удаления**; on web expand
the same section. Administrator preparation stores a **disabled** managed policy.
The owner then explicitly confirms permanent deletion. Revocation needs no
working storage or recovery evidence. Consent cannot select another owner,
library or arbitrary root.

Preparation requires the SHA-256 identifier of an **installed signed recovery
envelope**, not a free-form hash or checkbox. The server validates Ed25519 against
a separately installed operator public key, owner/scope, tested database restore
receipt, snapshot/export sample hashes, freshness (at most 24 hours), and every
filesystem identity. Missing, fabricated, expired or redirected evidence fails
closed. Follow [the recovery evidence procedure](../specs/testing/2026-10-10-trash-recovery-evidence.md)
for actual generation, private inputs and read-only trust-store installation.

The operator signing key is separate from account/API keys and never enters the
application container. Existing accounts, keys and permissions are unchanged.
The trusted operator must obtain real restore/export reports; a signature cannot
prove that a dishonest signer performed those operations. Sample recovery proves
the tested samples, not recoverability of every file.

Capture identities in the **running server container's mount namespace**, after
its final mount configuration. Host identities or another container's identities
do not authorize this application's root. Recreating the container, remounting
storage or replacing a root requires new evidence and preparation; preparation
resets consent. Install both public key and evidence directory as read-only binds
at the documented default paths. This is a separately reviewed storage-preparation
change to the server service, not a hidden change in the image-only helper. No
private signing key, NAS permission change or additional privileged service is
required.

An administrator can prepare another owner's `managed` scope through the existing
admin policy API with `enabled:false`; that owner grants consent through their
existing account. The admin policy API rejects `enabled:true` for managed storage;
only the owner's consent endpoint enables it. Managed originals can themselves be on Synology: proof must
cover their actual roots. Managed authorization never authorizes a library UUID.
External scopes remain disabled until individually prepared, tested and approved.
The existing external unlink path and its separate administrator/owner workflow
are described in [EXTERNAL-LIBRARY-DELETION.md](EXTERNAL-LIBRARY-DELETION.md).
Trash now lists every owned external library, including empty ones for revocation.
No managed permission enables these scopes.

## Filesystem boundary and interruption recovery

Policies bind canonical path, device/inode, mount ID/namespace/type/source,
mount root and target. Linux descriptor walks use `O_NOFOLLOW` on every ancestor.
Leaves must be exclusive regular files on the bound mount. Traversal, symlinks,
hardlinks, unsupported filesystems and changed identities are rejected.
Supported local ext4/xfs/Btrfs, overlay/tmpfs fixtures, and NFS/NFS4 use the explicit
guard; actual HP/NFS rename, directory-fsync, UID mapping and mount behavior still
require disposable operator acceptance. No filesystem permission is bypassed.
Owner-root validation compares mount backing coordinates as well as paths and
inodes. Nested bind aliases to another owner's storage are rejected; boundaries
are checked again during preflight and at the worker's destructive checks.
Ambiguous backing coordinates fail closed. NAS administrator-side remapping is
outside the application's mount-namespace evidence and needs operator review.

A receipt commits a random quarantine name before moving the entry into the
bound root's private `0700` `.gallery-deletion-quarantine` directory. The worker
rehashes the captured entry, checks fresh authorization, detects mutation during
that check, and unlinks through its anchored private directory. A last-moment
public-name replacement is retained or restored without overwriting the new
entry; it is never guessed and deleted. Watchers/scans exclude quarantine.
Ownership, checksum, shared-reference, policy and receipt locks remain enforced.

Authorization requires a controlled namespace: no hostile same-UID/root writer,
NAS-side namespace writer or retained writable descriptor during deletion. Such
actors can bypass directory protection or mutate an inode after any userspace
check. Do not authorize uncontrolled roots. An admitted operation holds a policy
share lock; revocation waits for that transaction and then blocks future work.
It does not cancel an unlink already linearized before revocation.

On interruption preserve the row, tombstone, receipt and named quarantine entry.
A verified retry uses that same committed identity. A raced symlink, directory,
hardlink or unexpected file may remain privately retained for individually
reviewed recovery; never recursively clean quarantine. Non-complete old receipts
without bound identity/quarantine metadata fail with `NO_ORIGINAL_IDENTITY_PROOF`;
they are not automatically rebound to current bytes. Preserve them for review.

## Scope and migration behavior

Selective deletion and Empty Trash preflight every scope before new receipts.
Missing or expired consent blocks the entire new selection and reports per-scope
reasons. Runtime I/O failure or concurrent change can still leave accurately
reported retryable outcomes; batch filesystem deletion is not atomic.

Migration `1793700000000-BindDeletionRecovery` adds root identities and recovery
expiry and disables unbound legacy grants. Rerun is safe. It changes no asset
IDs/status/timestamps/owners/libraries/files or tombstones. The 291 active offline
external index tombstones stay unchanged and outside user Trash. The 12 genuine
managed Trash assets remain restorable. No user intent is inferred from deletedAt.

## Deployment and rollback gates

Follow [RELEASE_RUNBOOK.md](RELEASE_RUNBOOK.md). Use the reviewed image-only helper
which checks effective Compose plus image worker defaults. Historical mutating
`deploy`, `rollback`, `enable-workers` entry points now stop before modification.
Both API and microservices must run; that grants no retention/deletion consent.

An unmodified build-9 rollback image lacks the new migration and hardened guard.
A target must contain the hardened capability and compatible migration inventory,
and pass startup against an isolated restored database. The helper rejects
incompatible images. Preserve the same original private image state for rollback.
Do not drop policy columns, tombstones, receipts or newer uploads. Image rollback
cannot undo unlink; file recovery needs verified backups and per-file approval.

## Required acceptance after approval

Use disposable media/accounts only, each existing user separately:

1. Missing/invalid evidence: preparation/deletion rejected; original survives.
2. Valid disabled preparation → owner consent → selective photo/video and Empty
   Trash; verify exact receipts and paired-media outcomes.
3. Mixed managed/unapproved external selection: no new unlink and clear Russian
   explanation. Other users, external originals and offline index stay intact.
4. Revoke, interruption/retry, Restore chronology, restart/delayed sync, OS denial
   and accurate local-copy results on S23/iPhone/web.
5. API **and microservices** healthy; thumbnail **and preview** complete for a
   disposable upload; Android/web viewing without gray tiles or white screens.
6. Isolated hardened rollback rehearsal; albums/search/faces, upload/sync,
   Live/Motion playback and Memories regression checks.

Source tests are not device or production acceptance. Deployment, managed consent,
external consent, Android signing and retention each require separate operator
approval. Existing retention guard stays disabled. No production queues are
cleared or activated by this task.
