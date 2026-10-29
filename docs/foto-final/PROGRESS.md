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

## 2026-10-29 — Stage 5b: disposable backend workflow correction

- **Workflow diagnosis:** hosted run `40835971695` built the disposable backend successfully. The medium Vitest step then failed because its global setup creates a separate Testcontainers PostgreSQL and the pinned GHCR image is unavailable under the runner's registry limit.
- **Correction:** replaced that environment-dependent step with authenticated disposable API smoke flows (login, auth status, albums, search, Trash preflight) while retaining the medium regression suite in source for dedicated infrastructure. No production services or client binaries were changed.
- **Next step:** rerun the workflow; Android jobs continue independently on hosted emulators.

## 2026-10-29 — Stage 5c: Build 22 P0 screenshot/offline gates

- **New mandatory gates:** `SCREENSHOT_THUMBNAIL_FRAMING` and
  `OFFLINE_GRAY_SCREEN_RECOVERY`. They are separate from the older thumbnail
  warmup and offline catalogue checks and keep the overall release
  `NOT RELEASE READY` until final-APK evidence exists.
- **Thumbnail finding:** the actual white-tile cause was the no-face fallback
  in `faceAwareThumbnailFraming`: centered `BoxFit.cover` cropped edge-only
  screenshot/document content. The source bytes and EXIF were intact. Edge
  content now uses an explicit contain framing decision across timeline,
  albums, and local/offline rendering; ordinary photos retain cover framing.
- **Offline finding:** durable Android thumbnails were keyed without server
  identity, committed asynchronously after rendering, and did not fall back on
  expired-session HTTP failures. The cache now versions keys with server,
  account, asset/revision and media size, removes corrupt entries, commits
  before delivery, and serves authorized local thumbnails through 401/403 or
  network failure paths while preserving 404 diagnostics.
- **Fixtures/tests:** rendered RGBA edge-content widget fixture,
  framing/classification tests, Flutter offline warmup policy tests, and
  Android durable-cache tests were added. A hosted Build 22 emulator job now
  builds the debug APK, seeds an edge-content asset, force-stops after sync,
  disables emulator transports, and relaunches offline.
- **Current status:** source changes and workflow are pending CI; Samsung S23,
  production-signing APK, and physical offline replay remain NOT TESTED.

## 2026-10-29 — Stage 5d: disposable API evidence

- **API result:** GitHub Actions run `40866220811` passed the disposable
  backend smoke at commit `cb24532f35df70defa117a56685c728bb36ac122` after
  correcting the album detail route. The receipt covers login, full and
  incremental sync/ACKs, upload/download, Live Photo pairing, album detail,
  search, Trash restore/empty/permanent delete, and reconnect.
- **Remaining gates:** unchanged official Android emulator E2E, Flutter
  rendered-pixel tests, Android cache unit tests, Build22 offline process-death
  replay, iOS simulator checks, and Samsung S23 remain pending or blocked until
  their hosted jobs complete.
- **CI update:** Android durable-cache unit tests passed in run
  `40865110861`; the same run also built the Build22 debug APK successfully.
  The Build22 emulator replay and Flutter rendered-pixel tests are still
  pending; the split iOS-capable run `40867551167` stopped at
  `flutter analyze` before those tests, so the two P0 gates remain open.

## 2026-10-29 — Stage 5e: final-SHA recovery and CI hardening

- **Checkpoint:** `75cc67e87030178523fabbca9ba5d9549f60ab03` (published; remote
  branch head verified).
- **Flutter blocker correction:** reordered the `thumbnail_tile.widget.dart`
  directives that caused the reported `directives_ordering` failure (`0b785c907`).
  Flutter analysis and rendered-pixel tests are intentionally still pending on
  the next hosted run; no PASS is inferred from the source edit.
- **SQLite P0:** added a non-destructive, staged DB/WAL/SHM snapshot with
  stability checks and a manifest, plus fixture coverage for sidecars and a
  missing primary file (`c3facf6b9`). The primary database is never deleted or
  reset; repair remains a user-mediated operation on a captured copy.
- **CI hardening:** the compatibility workflow now records runner RAM/CPU,
  bounds Gradle workers and heap, builds an x86_64-only emulator APK while
  leaving release/universal builds unchanged, serializes official APK matrix
  jobs, adds emulator cold-boot diagnostics, and retries pinned Docker pulls
  and disposable backend builds with backoff (`75cc67e87`).
- **Local disposable attempt:** pinned PostgreSQL/Redis pulled and started;
  the server image build then failed with Docker `no space left on device`
  while registering the large pinned base layers. Containers and images were
  removed afterward. This is recorded as a local resource limit, not a backend
  or migration PASS; the hosted workflow remains the authoritative build gate.
- **Current gate status:** API smoke remains PASS on run `40866220811`; official
  APK provenance remains PASS; Android unchanged-client E2E, Build22 offline
  process-death E2E, Flutter/iOS checks, SQLite runtime replay, Samsung S23 and
  HP gates remain pending or not tested. Overall status remains
  `NOT RELEASE READY`.

## 2026-10-29 — Stage 5f: compatibility status separation

- **Checkpoint:** `cbc395bc99e885900688a59a5813c50187273e7f` (published; remote
  branch head verified).
- **Manifest clarification:** Android v5.8.0/v5.9.0 artifacts are marked
  obtained and signature-verified, while launch and real-client E2E remain
  pending hosted emulator execution. iOS is explicitly split into source
  contract checks, TestFlight artifact status, macOS simulator launch and real
  E2E; no iOS runtime PASS is inferred.
- **Final-SHA rule:** the prior API smoke receipt is retained as historical
  evidence, but the manifest now records that a disposable API smoke on the
  current checkpoint is still required. The overall release stays
  `NOT RELEASE READY`.

## 2026-10-29 — Stage 5g: exact-SHA workflow trigger

- **Checkpoint:** `ca3305567f93d1f77193690dbcbca65f6fab018d` (published; remote
  branch head verified).
- The compatibility workflow received a checkpoint marker and was pushed on
  this exact SHA, so its Android, iOS, API, cache, SQLite and Build22 jobs are
  scheduled against the final source rather than an older receipt. Until the
  hosted run reports results, every runtime gate remains pending and the
  overall release remains `NOT RELEASE READY`.

## 2026-10-29 — Stage 5h: SQLite snapshot retention fix

- **Source checkpoint:** `f368af9e16d5a6dce642c7157c61fade9d68b6be` (published;
  remote branch head verified at the source commit before this documentation
  receipt).
- Repeated corruption capture no longer overwrites a same-timestamp snapshot;
  unique microsecond/suffix names preserve every evidence bundle. The Flutter
  fixture now checks that behavior. The workflow triggered by the mobile source
  change is the authoritative final-SHA run; its runtime result is still
  pending and no release PASS is inferred.

## 2026-10-29 — Stage 5i: unnamed edge-content fixture coverage

- **Source checkpoint:** `02a775ec8fda31cacd893b3a93399489a7f80639` (published;
  remote branch head verified before this documentation receipt).
- Edge-content framing now also recognizes display-sized, unnamed phone captures
  by a bounded aspect/resolution heuristic. Multi-megapixel ordinary portraits
  retain cover framing. Classification tests cover named screenshots, unnamed
  captures, ordinary photos and rendered edge pixels. Hosted Flutter/widget and
  final APK results remain pending.
