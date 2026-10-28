# FOTO Final RC — HP handoff (read-only preparation)

The release source for this handoff is the published RC commit recorded in
[`release-manifest-20261028.json`](./release-manifest-20261028.json). The
historical offline checkpoint is kept in the audit only; it is not a release
source and must not be passed to the HP preflight.

## Cloud evidence

- Source reference: `codex/foto-final-rc-20261028`
- Source/current RC SHA: `4bd351510bba8750f0f54d8777523d6603a44fdd`
- Android package: `de.opennoodle.gallery`
- Target version: `5.7.3`, `versionCode=22`
- Existing certificate digest: `ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`
- APK: not built or signed in Cloud; `apkSha256` remains null until HP produces and verifies the artifact.
- Release status: **NOT RELEASE READY** until HP, Samsung, iOS, backend staging and APK update checks pass.

## Safe HP preflight

Run from a clean HP worktree. A linked worktree is supported; the script uses
`git -C` and does not assume `.git` is a directory. It never fetches, switches,
resets, writes source files, installs an APK, or contacts production services.

```bash
export FOTO_REPO=/path/to/clean/foto-worktree
export FOTO_SOURCE_SHA=4bd351510bba8750f0f54d8777523d6603a44fdd
scripts/release/hp-preflight.sh \
  --repo "$FOTO_REPO" \
  --expected-sha "$FOTO_SOURCE_SHA" \
  --manifest docs/foto-final/release-manifest-20261028.json
```

The preflight must print `PASS read-only HP preflight`. Any SHA, origin, dirty
worktree or manifest mismatch stops the procedure. Do not use `git reset --hard`
or `git clean` to satisfy it.

## Read-only PostgreSQL audit

Use a disposable or owner-approved read-only database connection. Credentials
stay in the shell environment and are never written to the report.

```bash
export FOTO_PG_DSN='postgresql://read_only_user@127.0.0.1:5432/immich'
export FOTO_AUDIT_DIR=/path/to/private/audit
mkdir -p "$FOTO_AUDIT_DIR"
python3 scripts/diagnostics/hp-readonly-audit.py \
  --dsn "$FOTO_PG_DSN" \
  --output "$FOTO_AUDIT_DIR/library-audit.json"
```

The tool checks the real `users`/`assets` schema, inventories every owner,
separates checksum and `duplicateId` groups, reports External/Managed, stacks,
album links and Live Photo pairs, and records that visual similarity and
physical-file verification require a separate controlled step. Every query is
inside `BEGIN; SET TRANSACTION READ ONLY; ... ROLLBACK;`. The owner-scoped SQL
uses psql's quoted `:'owner'` variable through stdin; psql does not expand that
variable reliably in its `-c` execution path, so the script deliberately avoids
unsafe shell interpolation.

Do not delete assets, files, albums, stacks, faces, Memories or database rows
from this audit. Existing duplicates require a separate owner-approved dry-run
and dependency-preserving plan.

## Release order after this handoff

1. Verify the exact source and clean worktree.
2. Run the read-only database/NFS inventory against disposable fixtures.
3. Restore a disposable PostgreSQL backup and apply migrations there only.
4. Build backend/Web and run API, NFS fixture and compatibility tests.
5. Build Android with `versionCode > 21` using the existing HP key; verify package,
   certificate, SHA-256 and update over Build 21 without uninstalling.
6. Run Samsung/iOS/browser acceptance with a test account.
7. Obtain separate owner approval before any production switch or deployment.

Rollback is a source/image/APK selection operation using the previously verified
artifact; never erase production data or rotate the signing key as a rollback.
