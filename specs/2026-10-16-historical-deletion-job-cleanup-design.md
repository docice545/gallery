# Historical deletion-job cleanup

Gallery has one server Trash state: an owned asset with `status = Trashed` and
`deletedAt`. The web Trash page and mobile Trash page read that state. Mobile's
`trashed_local_asset` table is a device cache for offline sync and is not a
second server-side Trash or a source of deletion authority.

The queue cleanup endpoints provide the required operator-safe reconciliation
path for old deletion requests:

- `POST /api/queues/deletion-jobs/audit` is read-only and inventories only
  `AssetDelete`, `AssetDeleteCheck`, `AssetEmptyTrash`, and `FileDelete` jobs in
  the BackgroundTask queue. It categorizes jobs as active, recent, or obsolete
  using the caller-supplied UTC cutoff.
- `POST /api/queues/deletion-jobs/reconcile` removes only obsolete, non-active
  BullMQ job metadata. It re-fetches each job and checks `isActive()` immediately
  before removal, so a job becoming active is retained.

Neither endpoint invokes a job handler or changes `asset`,
`asset_deletion_tombstone`, storage roots, originals, derivatives, NAS paths,
or retention settings. Re-running the audit is safe; re-running reconciliation
is idempotent because removed jobs are absent. The audit response contains the
classification and removed IDs and should be retained with the operator's
existing database/queue backup evidence.

Active deletion jobs and all recent jobs remain intact. A stale job is not
treated as proof of user intent and is never replayed. Physical deletion and
NAS authorization continue to require the existing owner-scoped policy,
receipt, and recovery checks.
