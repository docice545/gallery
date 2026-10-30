# SQLite recovery validation for Build 22

Status: **PASS (Cloud regression tests); physical-device recovery remains open**.
The primary `immich.sqlite` database is a user-data boundary. Corruption,
`SQLITE_NOTADB`, I/O and full-disk failures stop unsafe sync writes and ACKs;
there is no automatic reset, deletion, replacement or promotion.

`captureSqliteRecoverySnapshot` copies the primary and existing WAL/SHM files
into a new directory. It checks size/mtime around the copy, retries primary
changes, and records changing/disappearing sidecars as omitted evidence.
An absent sidecar is distinguished from a lost sidecar using `FileStat.type`.
A sidecar that appears during capture is also recorded as omitted. Capture is
best-effort evidence, not a guarantee that every captured directory is usable
for recovery. Keep the original database and all sidecars together.

Before SQLite opens a diagnostic copy, recovery verifies the manifest version,
file inventory, sizes and absence of omitted sidecars. A nonempty WAL must have
a valid header, page size, salts and rolling checksums, complete frames and a
committed tail. This matters because SQLite can ignore a damaged WAL or suffix
and return `integrity_check = ok` for an older view missing pending operations.
Ambiguous/recycled or uncommitted WAL tails conservatively require manual
review, even if SQLite could recover part of them. No evidence is discarded.

A proven index-only failure is repaired with named `REINDEX` operations on a
separate candidate. `integrity_check`, `foreign_key_check` and table-content
fingerprints must agree before it is reported as repaired. Every receipt keeps
`promotionAllowed=false`; validation never replaces the primary. Page damage,
incomplete evidence and invalid WALs produce `requiresManualRecovery` with no
repair candidate. The operator must preserve the original evidence and compare
pending uploads/deletions, cursors, settings and row contents before any
separately approved recovery. `.recover` success alone is not proof of no loss.

## Regression evidence

The continuation reproduced two bugs before fixing them: absent WAL/SHM files
were incorrectly marked as omitted, and missing, truncated or checksum-damaged
WALs could be certified healthy. The tests use real SQLite files and committed
WAL-only pending rows; the primary database and WAL bytes remain unchanged.

```bash
cd mobile
flutter analyze --no-pub
flutter test --no-pub \
  test/data/db/sqlite_health_test.dart \
  test/data/db/sqlite_recovery_test.dart \
  test/infrastructure/repositories/sqlite_sync_recovery_test.dart \
  test/infrastructure/repositories/sqlite_sync_recovery_file_test.dart
```

All 15 tests passed locally with pinned Flutter 3.47.2. They cover healthy
snapshots, malformed pages, missing/truncated/damaged WAL, complete WAL-only
pending rows, real `SQLITE_CORRUPT_INDEX` 779, pending uploads/deletions during
copy-only index repair, and `updateAssetsV2` rollback/cursor preservation/replay.
The same four files run with strict exit propagation in the compatibility
workflow. See [release gates](RELEASE_GATES.md) for exact-revision CI lookup.

Power loss, low storage, device cold restart/account switching, real Android
SQLite behavior and the operator's backup/restore procedure still require
Samsung/HP acceptance. No physical database was opened in Cloud.
