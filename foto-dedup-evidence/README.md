# Evidence: FOTO Build 17 deduplication and sync acceptance

This directory contains original runner receipts plus filtered logs, indexed and hashed in
[evidence.json](evidence.json). It is **not** the canonical HP manifest, a recovery authorization,
a signed backup receipt or a release artifact. No real family media or production service was used.

Final code: `9cba0246791603e3ff1fbcffaa46e65124906522`. Receipts preserve their actual HEAD and
working-tree digest at execution time, including pre-commit dirty sources. They were not rewritten
to pretend the final commit already existed. Source-file hashes identify the final tested code.

- Final server phase: 15 admission PostgreSQL cases, 6 selected scanner cases and 223 repeated
  scoped backend unit cases PASS. Scanner excludes 70 cases by name; its original Vitest JSON
  and actual supervised-session metadata are included separately from native runner receipts.
- Previous phase: 129 PostgreSQL medium cases, 240 Flutter/SQLite cases, 39 automation cases PASS.
  Final server edits did not change mobile/automation code. Repeated subsets are not added again.
- Full backend coverage at the earlier checkpoint: 6878 PASS / 12 SKIP; one SharedSpace spec
  remains resource-BLOCKED. Its heap failure is reproduced on the exact unchanged baseline in
  the same environment. Initial all-spec collection also exhausted the heap. Neither is PASS.
- Full server formatting FAIL in two unchanged baseline files, also reproduced with the same
  formatter on baseline. Standalone dedup Flutter analyze FAIL131 requires separate editor
  integration/codegen. Changed timeline files analyze PASS; editor's full analysis PASS is linked
  from the acceptance report, not attributed to this independent branch.
- Historical library/upload 177-case evidence belongs to its recorded older source/dirty digest,
  includes historical public RAW fixtures, and is not a fresh all-synthetic run or final-head PASS.
- Logs named `before-*` intentionally record reproduced failures and intermediate faults. No
  assertion was weakened to turn them green. Empty ESLint stdout is accompanied by the observed
  exit result, without an invented machine receipt.

Real PostgreSQL/SQLite and disposable local filesystem tests are distinct from mocked native APIs,
queue/events and HTTP integrations. Actual NFS/Synology root squash, device permissions/background
sync, local HP patches, a combined merged build, signing and production rollout remain unverified.
Full results and precise scope are in [DEDUP_NAS_ACCEPTANCE.md](../DEDUP_NAS_ACCEPTANCE.md).
