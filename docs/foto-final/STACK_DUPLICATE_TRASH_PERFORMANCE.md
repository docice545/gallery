# Stack / dedup / Trash performance acceptance

## Stack deletion

The selected collapsed cover is expanded to a server-verified UUID set by
`AssetService.resolveStackTrashIds`. The action is used only for a main Photos
timeline selection. Viewer, album, map, search and Trash selections remain
frame-specific. The code never calls `DELETE /api/stacks/{id}` as a substitute
for asset deletion; unstacking and deletion are separate operations.

The restored implementation is present at `dd1cab300` and is covered by the
mobile action tests, `mobile/test/domain/services/stack_trash_selection_test.dart`,
and the disposable PostgreSQL/storage medium suite
`server/test/medium/specs/services/stack-trash-selection.spec.ts`. The suites
cover whole and partial stacks, mixed selections, stale/missing membership,
404/503 lookup failures, restoration, final deletion, sync tombstones and
preservation of unselected frames. Flutter and medium-device execution remain
blocked in this Cloud session.

## Duplicate root cause and safe handling

The historical `chudo_anna` pairs are an External row and a Managed row with
the same bytes. They are different asset identities and different paths. The
safe fix is admission-time content identity plus owner/library scope; a path
change or a re-scan must not create a second identity for an already verified
External original. The branch contains `af4395683` and its follow-up upload
admission tests. The existing planner in `scripts/external-upload-dedup/plan.mjs`
is review-only and has no apply mode.

`scripts/external-upload-dedup/hp-readonly-audit.py` adds a per-owner HP audit.
It reports managed/external counts, file hashes and sizes, exact byte duplicate
groups, album/face/memory/stack/Live Photo relations, inaccessible files and an
estimated reclaim size. It never removes or remaps anything. Run it first for
`chudo_anna`, then for every other owner. Keep the six known pairs and the
previously dissolved 757 stacks under explicit review; do not re-enable
`STACK_EXCLUDED_OWNERS` for that owner.

## Empty-Trash bottleneck

The durable batch implementation and Android progress/cancel UI are present at
`3874d4016`, `58ec688cb`, `6551f81fd`, `1bd3ec0cd`, `44e3e5911`, and
`41f13c2c9`. The audit found a concrete backend bottleneck: each mobile status
poll called `deletionStatus` for every asset, which then performed parent,
operation and companion receipt queries. A 5,000-item batch therefore caused
an N+1 query storm every 250 ms.

The RC changes `AssetRepository.getDeletionReceipts` to load all parent and
operation tombstones in two owner-scoped queries. `AssetService.deletionBatchStatus`
aggregates those rows in memory and still reports complete, failed, pending and
blocked items from durable receipts. The operation remains idempotent, owner
scoped and restart-safe; it does not hide files or claim physical deletion
before the worker receipt is complete.

Cloud evidence: the 239-test `AssetService` suite passes, including the new
single-repository-call gate, and the read-only duplicate planner has 31 passing
tests. Real p50/p95 timings, SQL counts, Redis/queue load and Synology/NFS
behaviour are **BLOCKED** until a disposable HP staging stack is available.
No performance number is claimed here.

## HP benchmark scenarios

Use a disposable owner/database/NFS fixture and record raw JSON receipts for
10, 100, 500 and 1,000 assets. Each set must mix JPG, HEIC, video, Live Photo
JPG+MP4, Managed, External, stacked and temporarily missing files. Record UI
response, queue acceptance, durable status completion, total deletion time,
HTTP/SQL counts, CPU/RAM, NFS operations, retries and failed IDs. Compare the
same fixture before and after the RC. Production NAS and production PostgreSQL
must not be used.
