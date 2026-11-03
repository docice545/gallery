# Build 36 artifact migration-source baseline

The artifact-only workflow previously compared source migrations against
`ea51a8acdc6f18ab5917c19b6f3833d740b4e9ba`. Run `41675184231` correctly stopped
before image building because an existing migration had different bytes.
The guard was not removed or changed to ignore whitespace.

The difference is inherited from commit
`ae48787ec7160c09b643aa4c7b5fa765ac393711`, before the owner-supplied Build 35 source
`0c8be542121d415f4d748dda20367044cd200d40`:

- `1793400000000-FixMemoryCandidateSchema.ts` had two `.execute(db)` calls wrapped
  over multiple lines. SQL statements are unchanged, but the immutable byte guard
  appropriately treats even formatting changes as a mismatch.
- Seven migration files were added between that older reference and Build 35.
- The reviewed Build 35 source is an ancestor of Build 36. All **175** migration
  source paths and SHA-256 values are identical between Build 35 and Build 36
  source `643d0a79e`; no files were added, removed or changed in that comparison.

The workflow now uses the explicit Build 35 source pin. Its regression test
verifies ancestry and every existing migration byte. Existing negative tests
continue to reject modified/removed migration files and a nonancestor baseline.
No migration source, SQL, database or runtime behavior was modified by this fix.

Inventory fingerprint for the Build 35 source: SHA-256
`33a141c8a8a09c590418bc331b9515b8b3f69d559dcb74eb3b68895e86771da8`.
It is computed from UTF-8 compact JSON of sorted `(path, fileSHA256)` pairs in
both migration directories. It is **source evidence**, not a database backup or
an applied-migration receipt.

The real HP PostgreSQL migration ledger, schema, existing data and running Build 35
image remain **NOT VERIFIED in Codex Cloud**. Production preflight, backup/restore
verification and operator approval for cutover are still mandatory. The source
baseline update permits an isolated artifact build; it does not authorize or
prove a production migration or rollback.
