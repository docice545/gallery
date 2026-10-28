# FOTO final RC progress

This journal is append-only by checkpoint. It records source changes and real
verification statuses so a new Cloud session can resume from the last published
commit without repeating destructive work.

## 2026-10-28 — Stage 0: integration baseline

- **Base:** `2eb2816f94647587a60c9b0e014bfdb30152fa08` (`fix/foto-offline-library-20261027`).
- **Checkpoint:** `ed425f9e7` (audit boundary documentation plus this journal).
- **Scope:** selected the complete offline/remote-Live-Photo/migration line as the RC base; verified the
  historical branch and migration `1796000000400-AddVerifiedAssetContentChecksum` are present.
- **Cloud checks:** Git refs and source inspection PASS. Flutter, Android device, iOS device, HP,
  Samsung, production API and NFS checks BLOCKED by environment access/tooling.
- **Production:** unchanged. No APK build, installation, backend migration or publish to production.
- **Next safe step:** publish this journal, then audit Stack deletion, all-library duplicate detection and
  Android empty-Trash performance independently.

## Resume protocol

1. Read this file and `PROGRESS.json`.
2. Verify the published branch HEAD and working-tree cleanliness.
3. Continue only from the last checkpoint whose tests are recorded here.
4. Keep destructive NAS and production operations behind explicit HP approval.

## 2026-10-28 — Stage 1: Stack, duplicate and Trash gate

- **Checkpoint:** `0d1142157d6d6f6901cc6ffa1d951ac4c3d78e9b` (published).
- **Source changes:** added owner-scoped two-query deletion receipt aggregation and a read-only per-owner HP
  duplicate auditor. Confirmed `dd1cab300` and the seven historical Stack/Trash batch commits are ancestors.
- **Checks:** `pnpm --dir server exec vitest --config test/vitest.config.mjs run src/services/asset.service.spec.ts` —
  PASS (239 tests); `node --test scripts/external-upload-dedup/plan.test.mjs` — PASS (31 tests);
  `python3 -m py_compile scripts/external-upload-dedup/hp-readonly-audit.py` — PASS; `git diff --check` — PASS.
- **Blocked:** Flutter tests, medium PostgreSQL/NFS timing runs, Samsung UI and HP duplicate inventory.
- **Next safe step:** publish this checkpoint, then run the remaining Web/server/inpainting checks and assemble the
  release manifest and HP preflight package.

## 2026-10-28 — Stage 2: release handoff package

- **Checkpoint:** `018a9f0422788d78494ba7697afb4de5535e37e7` (published).
- **Source changes:** prepared `scripts/release/foto-final-rc-20261028/`, kept dangerous HP actions outside Cloud,
  and advanced the mobile source version to `5.7.3+22` so a future APK can update Build 21.
- **Checks:** HP preflight shell syntax PASS; APK build/signing and device upgrade are NOT TESTED/BLOCKED by
  policy and unavailable SDK/key.
- **Next safe step:** publish this checkpoint, then commit the machine-readable release manifest and create the
  integration PR when GitHub credentials permit it.

## 2026-10-28 — Stage 3: release manifest

- **Checkpoint:** `00aefbdb7a696ebbb55f2e5ccac1f6ed1ffbacb7` (published).
- **Source changes:** added `release-manifest-20261028.json` and a clean-checkout generator with source/file
  SHA-256 provenance. The manifest records real gate statuses and keeps `overall=NOT_RELEASE_READY`.
- **Checks:** JSON/Python validation PASS; no APK, production, HP or device operation was executed.
- **Next safe step:** create or update the integration PR; GitHub CLI authentication must be restored for API PR
  creation. The branch itself is already published and resumable.

## GitHub publication status

- Branch: `https://github.com/docice545/gallery/tree/codex/foto-final-rc-20261028`.
- PR creation: **BLOCKED** in Cloud (`gh pr create` returned `403 Forbidden`; configured `GH_TOKEN` is invalid).
- Recovery URL: `https://github.com/docice545/gallery/compare/main...codex/foto-final-rc-20261028?expand=1`.
- No force-push was used; all checkpoints are linear and published.
