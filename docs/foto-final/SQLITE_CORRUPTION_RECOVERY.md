# `SQLITE_CORRUPTION_RECOVERY` release gate

Status: **SOURCE FIX / FLUTTER AND DEVICE RUNTIME PENDING**.

The primary `immich.sqlite` database is a user-data boundary. Startup still
runs a health probe and stops unsafe writes on corruption, `SQLITE_NOTADB`, I/O
and full-disk errors. It does not call `Drift.reset()`, delete the database,
clear the app, or retry a failing sync forever.

`captureSqliteRecoverySnapshot` creates a timestamped staging directory and
copies the primary database together with existing `-wal` and `-shm` sidecars.
It compares source file size and modification time before and after copying,
deletes only an incomplete staging directory, and atomically renames a stable
snapshot. A manifest records the reason and file metadata without account
tokens or media content. The source database and local assets, pending
uploads/deletions, cursors, album links and settings are never mutated by this
capture operation.

Repair is deliberately a separate, user-mediated operation against the
captured copy. The operator must run `PRAGMA integrity_check` and
`PRAGMA foreign_key_check`, then use a targeted `REINDEX` only when the
diagnosis proves an index-only failure. A page/WAL failure requires SQLite
`.backup`/`.recover` into a new file and record comparison before any future
explicit replacement. No partially recovered file is promoted automatically.

Evidence:

- `mobile/lib/data/db/sqlite_health.dart`
- `mobile/test/data/db/sqlite_health_test.dart` (sidecars, stable source,
  missing primary)
- `mobile/lib/data/data_controller.dart` (unsafe-write startup stop)

The remaining runtime matrix is not claimed as passed: corrupt index/page/WAL,
truncated write, low storage, crash during recovery, cold restart, account
switch, Trash/Restore, and offline warmup/process death all require hosted
Flutter/Android execution and a Samsung replay where available.
