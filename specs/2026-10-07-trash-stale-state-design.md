# Mobile: persisted Trash wins over unversioned asset replay

## Proven repository defect and scope

The normal/Live Photos timeline already excludes `remote_asset_entity.deleted_at`
and suppresses checksum-linked local copies, and the existing Android local-hash
and server library-rescan fixes remain intact. However, both mobile asset-stream
upserts previously overwrote a known non-null `deletedAt` with null. A delayed
pre-Trash asset page or another owner/partner/album/library/Space projection could
therefore clear the persisted state and make the same identity visible again.
The old replay tests repeated **current** trashed state, not the older active
payload, so they did not cover this transition.

`SyncAssetV1` and `SyncAssetV2` contain `fileModifiedAt`, which is media filesystem
mtime, **not** a revision of Trash state. It cannot establish that null means a
newer restore. This defect is reproduced with deterministic SQLite fixtures;
it is a proven software path, not proof that every physical-device occurrence
reported by the user had this exact cause.

## State contract

- Newly delivered active assets are inserted normally. An upsert with null
  `deletedAt` never clears an existing tombstone on conflict.
- The existing successful native Restore/Restore All actions still update the
  local DB after API success. They clear any retained reset tombstone atomically.
- Before processing an asset-bearing sync batch, only IDs that are already
  known trashed and whose incoming state is null are checked through the existing
  `GET /assets/{id}` endpoint. The same asset ID and owner must be returned.
  `isTrashed=true` keeps the tombstone; `false` permits the restore.
- Restore confirmation compares the persisted identity, checksum and deletion
  snapshot transactionally, including the endpoint scope and opaque local
  mutation revision. A newer local Trash operation, changed identity, or changed
  retained record invalidates the earlier confirmation. A same-second
  restore→retrash cannot be mistaken for the original SQLite date (ABA).
- Failure/null/mismatched owner prevents ACK of that batch. The existing sync
  retry resolves it later; uncertainty never exposes the asset. Cancellation
  after the HTTP response causes neither a DB mutation nor ACK.
- All V1/V2-bearing projections go through this boundary. The non-stream upload
  placeholder remains `INSERT OR IGNORE` and atomically inherits a retained
  tombstone if reset has removed its old row, so it cannot bypass Trash state
  either before or during reset. Stack/EXIF/metadata writes do not touch `deletedAt`.

There is no polling, per-thumbnail request, widget-only exclusion or server/API
change. A GET occurs only for a conflicting Trash-to-active transition. This may
temporarily keep a genuinely restored asset hidden while the network is offline;
it becomes eligible after the authoritative check succeeds.

## Reset, restart and privacy

`SyncResetV1` must rebuild remote entities, including rows that may no longer be
authorized. Before that destructive cache reset, the same SQLite transaction
retains only known trashed identities in the existing `settings` table. Every
successful local Trash operation also writes an opaque UUID revision there, so
the guard works even before any reset and survives same-second mutation races.
Entries
use `sync.trash-reset.<endpoint SHA-256>/<owner>/<asset>` and hold asset ID, owner,
checksum, deletion time, local mutation revision and the existing endpoint scope. They contain no media,
filename, original path, token or API key and never recreate remote/user rows.
No DB schema migration or parallel asset model is introduced.

Replayed active rows inherit the retained tombstone. Until a remote row is
re-delivered, main/Live Photos SQL also suppresses its local checksum twin.
The subquery scopes by current endpoint and timeline owners; its indexed key
range and non-correlated `NOT IN` set avoid scanning all tombstones for every
local asset. Unhashed local files cannot be identified by this checksum contract
and retain their existing behavior.

The guard survives SQLite reopen and repeated reset. An unversioned re-delivery
does not discard a local mutation revision; confirmed restore or server deletion
removes the retained record. Explicit logout uses `retainTrash:false`, clearing
the retained account metadata as well as normal remote cache. A different owner
or server endpoint does not inherit the old state. Temporary tombstones contain
only local cache state and never mutate the server or originals.

## Regression verification and physical boundary

Tests cover V1/V2, managed/external media, a delayed active payload, local checksum
twins, ordinary and year-scoped Photos/Live Photos, reset before asset re-delivery,
SQLite reopen, owner/endpoint isolation, logout, conditional newer-Trash races,
same SQLite-second restore/retrash and late confirmation (verified to fail before
the mutation-revision correction),
successful single/bulk Restore, permanent Delete, HTTP failure without ACK,
cancellation, and real repository + service confirmation for both stream versions.
Existing deletion-date grouping, stacks and Live/Motion pair tests remain enabled.

Samsung acceptance still requires: Trash a backed-up still/video/Live Photo;
scroll, paginate, refresh, background/foreground, restart and reconnect; confirm
the item remains only in Trash on mobile/web; Restore and confirm the original
timeline date and pair return without duplicate assets. No production or physical
Samsung/iPhone operation was performed by this change.
