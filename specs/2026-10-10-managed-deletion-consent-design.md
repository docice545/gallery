# Managed permanent-deletion consent

## Diagnosis and evidence

Production application baseline: `e6ab95e695f085c3016072ebff44d4ba02695cb5`.
The owner verified all 291 external `Active + deletedAt` rows are `isOffline=true`,
with an active library. They are offline index tombstones, **not user Trash**.
The historical scanner writes `deletedAt` for offline assets. Historical user
Trash already writes `status=Trashed`. A date alone never establishes user intent.
No conversion, data migration, restoration or file deletion is justified.
A previous UI/count based only on `deletedAt` could have counted offline rows;
this does not establish that those rows were previously user-trash assets.

The 12 managed `Trashed + deletedAt` assets are genuine Trash. With no policy row,
`LIBRARY_DELETION_NOT_AUTHORIZED` is the correct fail-closed result. The missing
piece is an explicit, accessible consent workflow, not an alternative NAS API.
The October 2 managed-file deletion test remains evidence for that one asset.

## Existing mechanisms retained

Authentication, accounts and API keys are unchanged. `asset_deletion_policy`,
`asset_deletion_tombstone` and the existing AssetDelete lifecycle are reused.
No new service, table or migration is introduced. Root validation, owner/scope
checks, canonical paths/inodes, hashes, shared-reference protection, paired-media
checks, receipts, restore exclusion and retention guards remain in place.
Automatic retention remains skipped. Managed storage can itself be NAS-backed;
"managed" does not mean "physically on HP".

## Permission boundary

1. Administrator preparation: verify real backup recovery and exclusive roots,
   supply the SHA-256 of that verified evidence, derive existing own managed roots
   on the server, validate current filesystem/owner boundaries, store **disabled**.
   Evidence is an administrator attestation using the existing trusted-admin
   contract, not an automatic recovery test. The server cannot validate an
   operator's private recovery report merely from its digest.
2. Owner consent: separate destructive warning; enable only their own `managed`
   policy. The request cannot choose an owner, scope, roots or recovery proof.
   Current roots are revalidated while the policy row is locked. A concurrent
   administrator update cannot be overwritten by stale policy data.
3. Revocation: update only that managed policy's enabled flag. No writable storage
   is required. The administrator proof/actor and roots are retained.
4. External scopes remain separately protected and disabled by default. Neither
   preparation nor consent creates/enables an external policy.

Non-admin users ask their existing administrator to prepare a disabled managed
policy using the existing admin-only `PUT /assets/deletion-policy` (owner-scoped,
verified roots/proof). They then grant/revoke consent in Trash. No new credentials.
An admin can prepare their own roots directly in the same UI.

## Additive API

All paths below are relative to `/api` and require the existing authenticated session.

| Method/path | Permission | Effect |
| --- | --- | --- |
| GET `/assets/managed-deletion-policy` | asset.delete | Own enabled/prepared/canPrepare booleans; no paths/proof |
| PUT `/assets/managed-deletion-preparation` | admin + systemConfig.update | Own verified managed preparation, enabled=false |
| PUT `/assets/managed-deletion-consent` | asset.delete | Own managed consent, `{enabled, confirmed:true}` |
| POST `/assets/permanent-deletion/preflight` | asset.delete | Read-only, max 200 IDs; id/scope/authorized/code |
| GET `/trash/empty/preflight` | asset.delete | Own Trash count/authorization per scope |

Permanent-deletion results gain optional `scope`; existing clients remain
compatible. Selective deletion refuses the whole submitted batch if any scope,
owner or Trash-state precheck fails. Empty Trash checks all scopes first. Both
clients preflight the full selection across chunks before the first mutation.
The worker still independently verifies current policy and file identity; a
preflight is not a deletion grant. Concurrent revocation or a later unlink
failure can leave prior irreversible actions complete: clients retain those
receipts and stop unsent batches on an authorization failure, without reporting
false all-or-nothing success.

`getOwnerTrash` now follows the timeline Trash predicate: dated Trashed rows or
Deleted rows with an incomplete receipt. Active offline rows and bare/completed
Deleted index rows are excluded. UI uses Russian permission/scope explanations;
unknown failures remain incomplete, never success.

## Production boundary

See [operator instructions](../docs/MANAGED-DELETION-AUTHORIZATION.md).
This patch does not build a release or authorize deployment/real deletion.
No automatic grants, Trash emptying, queue changes or NAS writes occur on startup.
The healthy API + microservices configuration must be retained. The historical
API-only release worker gate is unsuitable for this update without a separately
reviewed replacement; it previously stopped thumbnail/preview processing.
