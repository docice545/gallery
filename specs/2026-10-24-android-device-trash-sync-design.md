# Durable Android device-trash synchronization

Android trash is an independent side effect of a server deletion. Failure to
mutate MediaStore must not prevent discovering or backing up new photos, or
processing the remaining server events.

The production baseline is `e5883358c48a76a82fe7db29b5cd5ac0b1fc76e2`.
Its pinned `photo_manager` 3.9.0 resolves every ID before constructing a single
trash request. An unavailable, already-trashed or stale ID can fail that entire
request. The plugin reports the generic `deleteWithIds failed` code and discards
the original exception. Its successful activity callback returns the requested
IDs without verifying each row. These code paths explain the lost error detail
and batch failure mechanism; they do not establish which condition occurred on
a particular Samsung device or establish an Android 16 platform defect.

## Persistence and acknowledgement

`TrashedLocalAssetRepository` owns device-trash intents in the existing Drift
`settings` table. Its `local-trash.v1` namespace is scoped to the authenticated
owner and server endpoint. Each asset has one intent containing its verified
local revision, album membership, authorizing remote IDs, retry deadline and
last failure. This reuses the existing repository and metadata store without
changing the database schema. The actual trashed-asset table continues to
describe observed trash, never an uncompleted request.

Remote handlers commit intents before ACK and before removing permanently
deleted remote metadata. ACK confirms durable event delivery; it does not
confirm an Android deletion. A persistence failure prevents ACK. Replayed
events merge with the same intent without resetting retry state. A terminal
remote deletion remains actionable after its remote row disappears. A server
Restore cancels the corresponding nonterminal intent and never restores device
media.

One bounded pass claims up to 32 due intents using transactional leases shared
by sync engines. Compare-and-swap tokens protect completion and retry state
from stale workers. A crash leaves a recoverable two-minute lease. Failures use
persistent exponential backoff from one minute to six hours; there is no active
retry timer. Regaining MANAGE_MEDIA makes permission-blocked intents eligible.
Changed local revisions and deselected backup albums cancel stale intents
instead of authorizing deletion of different content.

Local sync discovers and checkpoints MediaStore changes and records intents;
remote sync persists and acknowledges event batches. Neither sync method waits
for an Android mutation. The foreground manager owns a separate cancellable
trash task, while the Android background worker runs its owned trash phase only
after backup. Foreground maintenance owns a dedicated isolate outside the
bounded sync/hash pool, so an outstanding Android request cannot monopolize the
only worker needed to prepare an upload. Cancellation waits for the trash task's actual unwind before its
database and provider resources are released. Platform failures are recorded against each intent
and logged with their diagnostic code; unrelated synchronization can proceed.
Database failures retain the existing intent and are logged as maintenance
failures. Only a native-verified `trashed` or `alreadyTrashed` outcome atomically
updates the actual trash table and completes the intent.

## Android operation

The automatic sync path uses a dedicated trash-only native operation. It never
calls permanent deletion and never changes server media. Each numeric typed
MediaStore ID is queried with `MATCH_TRASHED=INCLUDE`; stale/missing rows do not
poison other items. Name, type and timestamps must match the expected revision
before a write. Already-trashed rows complete without rewriting the row or
refreshing its expiry.

MANAGE_MEDIA does not itself grant direct write access. MediaProvider can
require `MediaStore.createTrashRequest` for another application's camera-owned
row, even when PermissionActivity skips its confirmation dialog. The operation
first attempts an allowed direct trash update, then uses that system request
when needed. Missing permissions, unavailable foreground activity, cancellation,
provider failures and timeouts produce distinct retryable outcomes. No permanent
delete fallback exists. Requests are bounded, have one in-flight owner per
engine, and finish on activity detach or a finite native timeout.

After Android reports a result, every row is queried again. RESULT_OK alone
does not prove success. Missing or inaccessible rows remain pending, while
confirmed partial success completes only the corresponding intents. An OS
request already launched cannot be rolled back by a later server Restore; later
reconciliation observes its actual result and never recreates media silently.

## Release validation boundary

Unit and SQLite regression tests use mocked platform operations and synthetic
database rows. Native policy tests do not access a media library. Automated
checks cannot prove Samsung MediaProvider behavior, OS permission UI behavior,
production certificate identity or installation over the deployed Build 17.
Those checks remain mandatory on a physical device before production rollout.
