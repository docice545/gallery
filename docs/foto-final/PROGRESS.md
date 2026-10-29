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

- **Checkpoint:** `de5c94409b9e01d28a2929eb3defd3b481364ed1` (published; manifest sealed after the generator commit).
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

## 2026-10-28 — Stage 4: resumability and PR handoff

- **Checkpoint:** `06754793212e91311d675803b5609fe18ecf53aa` (published).
- **Files:** progress journal, release gates and PR handoff status.
- **Result:** branch publication PASS; PR API creation BLOCKED by invalid Cloud GitHub token.

## 2026-10-29 — Stage 5: original Noodle Gallery compatibility gate

- **Branch:** `codex/foto-master-final-20261029`, based on published `codex/foto-final-rc-20261028` at `8910f0281cdcec731b585a9e0efdefcba59827e5`.
- **Source changes:** added the machine-readable original-client contract manifest, OpenAPI compatibility tests, acceptance matrix, and a GitHub Actions workflow that downloads official Android APKs, starts disposable FOTO services, and runs the unchanged APKs on a hosted Android emulator.
- **PR #7:** required compatibility commit `a3d51348003b5e1fd84aa26040161f071fc4d648` is an ancestor of the selected RC.
- **Artifact checks:** official v5.8.0 and v5.9.0 APKs downloaded; SHA256 and APK v2 signatures verified; package `de.opennoodle.gallery`, certificate SHA256 `c1a77384cf726ba6ef0ac7ef51acd124e49941d123a2530615dd51a80c5b57c3`.
- **Automated checks:** API contract tests PASS (11 tests); TypeScript check PASS after building SDK/plugin SDK; shell/YAML validation PASS.
- **Runtime status:** local emulator image installed but cannot start because this worker has no KVM/VMX/SVM. Hosted emulator job is added and must complete before Android E2E is PASS. iOS TestFlight/simulator remains NOT TESTED without macOS.
- **SQLite:** primary database startup health guard integrated from checkpoint `5aa533cc9e42cc940bfc88e8577588ba36d0d8e0`; Flutter compile/device validation remains pending.
- **Production:** unchanged; no HP, NAS, production database, or real user data touched.
- **Next stage:** push this checkpoint, verify remote SHA, then run the hosted compatibility workflow and disposable PostgreSQL regressions.

## 2026-10-29 — Stage 5a: hosted workflow diagnosis

- **Workflow run:** GitHub Actions run `40835596166` failed in 34s before tests. The API job used an invalid pinned `actions/setup-node` SHA; both Android jobs exited 127 because `apksigner` was not on PATH.
- **Correction:** replaced the setup-node pin with the repository's valid v7 pin and invoked `$ANDROID_HOME/build-tools/35.0.0/apksigner` explicitly. No client or production files changed.
- **Next step:** publish the correction and rerun the hosted workflow; retain the failed run as a diagnostic receipt.
