# Backend release evidence — 2026-10-16

This record covers the historical deletion-job cleanup endpoints and the bounded
`AssetDeleteBatch` worker. All destructive checks used disposable PostgreSQL and
filesystem fixtures. Production Compose, production PostgreSQL/Redis/storage, VPN,
NAS mounts, and real photographs were not accessed.

## Checks

| Check                                | Result  | Evidence                                                                                                                |
| ------------------------------------ | ------- | ----------------------------------------------------------------------------------------------------------------------- |
| Targeted backend tests               | PASS    | `server`: 4 files, 287 tests; queue controller, controller registry, job repository, and asset service                  |
| TypeScript check                     | PASS    | `cd server && pnpm check`                                                                                               |
| Disposable batch matrix              | PASS    | `batch-matrix.jsonl`; 1/10/100 use the inline path, 1000 uses the bounded worker                                        |
| Batch worker measurement             | PASS    | 1000 synthetic assets: 277170 ms, 3.608 assets/s, RSS delta -6381568 bytes                                              |
| Historical-job audit/reconcile smoke | PASS    | Isolated image smoke: authenticated audit and reconcile both returned HTTP 201 with zero synthetic jobs changed         |
| Web Trash/delete regression          | PASS    | Vitest: 4 files, 28 tests; queued completion, cancellation, partial acknowledgement, preflight and Trash-page semantics |
| Mobile Trash/delete regression       | PASS    | Flutter: 3 files, 26 tests; aggregate polling, reconciliation, explicit cancel and selection preservation               |
| Real Synology/NFS validation         | BLOCKED | No separate disposable Synology test directory/export is available                                                      |

The 1/10/100 rows report `elapsedMs=0` for the batch worker because those requests
remain intentionally inline and do not invoke the worker. They are correctness
fixtures, not HTTP latency measurements. The 1000 row verified complete durable
receipts and absence of every synthetic original file. A separate 401-item
interruption/recovery run stopped after the first 200-item chunk and resumed with
the same payload; all receipts completed and all synthetic files were removed.

## Safety boundary

`POST /api/queues/deletion-jobs/audit` is read-only. The reconcile endpoint removes
only obsolete, non-active BullMQ metadata and never invokes a deletion handler or
touches assets, receipts, originals, derivatives, NAS paths, or retention state.
Historical requests are never replayed. Current deletion requests retain the
owner-scoped preflight, durable receipts, advisory lock, Live Photo pairing, and
idempotent retry protocol.

The disposable Docker image used for the isolated smoke was
`gallery-server:autocodex-20261016` with local manifest digest
`sha256:a54af0beb186cd5af257b59befe6c11f05e8a995d86b866bdd36e08b66cc6897`.
It was removed after the smoke; no registry publication or production deployment
was performed.

## Remaining release gates

- Real Synology/NFS validation remains pending until an explicitly separate test
  export is available.
- Aggregate batch status/progress is implemented in this stage: large deletion
  responses include a deterministic owner-scoped `batchId`, and
  `GET /api/assets/permanent-deletion/status?batchId=...` reports aggregate
  complete/failed/pending counts from BullMQ plus durable receipts. Completed
  and failed batch metadata is retained for seven days for refresh/recovery.
  Cancellation is implemented as an owner-scoped durable stop request: the
  worker checks it before each bounded 200-item chunk, leaves already-started
  work to finish, and reports `cancelled`/`cancelRequested` without undoing
  completed deletion.
- Web asset-viewer, selection, timeline and gallery paths all use the same
  acknowledgement-vs-completion flow. Mobile Empty Trash captures one owner
  snapshot, shows aggregate progress, supports explicit cancellation after a
  `batchId`, and reconciles only confirmed `complete` receipts. A cancelled
  selection is not implicitly retried.
- This is contract/regression evidence, not real-client compatibility evidence.
  No upstream Android APK or iOS IPA was run against this server; no device
  upgrade, signed Build >=13, or iOS archive was produced in this stage.
- The locally retained release APK from an earlier Build 11 run is
  `/mnt/hp-data/codex-work/gallery-auto/20261016-100448-3611623/artifacts/Foto.apk`
  (package `de.opennoodle.gallery`, version `5.7.3`, versionCode `11`, SHA-256
  `0e294e9f5e77a29b856c37f8e9d71acb4736b6ec3439b16ba80dd06ea12d1286`, signer
  `ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`). It is
  not an upgrade artifact for the reported installed Build 12 and is not
  attributed to the current commit. The checkout has no `key.jks` or
  `key.properties`, so producing the authorized `foto` Build >=13 remains
  blocked pending the existing signing environment and approval.
- Production audit, deployment, and any cleanup of production queue metadata
  require a separate explicit operational step.
