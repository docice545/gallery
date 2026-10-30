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

## 2026-10-29 — Stage 5j: exact-SHA disposable API smoke

- **Source checkpoint:** `46e013adaddeddf8d9b358bcd10b5f721270e0ed` (published on
  `codex/foto-master-final-20261029` and `main`).
- **Test harness:** `tools/original-noodle-gallery/api_smoke.sh` now generates
  unique media bytes and filenames, so a rerun after permanent deletion does
  not hit the server's intentional reupload suppression.
- **Backend setup:** `pnpm --dir server build` PASS; 79 Gallery migrations
  synchronized and disposable pinned PostgreSQL/Redis started. The Node API
  worker completed migrations and reported no schema drift.
- **Exact-SHA API result:** PASS on the rebuilt backend at the source checkpoint
  above. The smoke covered login, auth status, full/incremental sync and ACKs,
  upload/download, Live Photo pairing, albums, search, Trash restore/empty/
  permanent delete, and reconnect. Download polling observed transient 404s
  while processing and then passed once original and thumbnail files were
  available.
- **Gate separation:** this closes the disposable API evidence requirement;
  official Android APK launch and unchanged-client E2E, Build 22 offline
  process-death replay, Flutter rendered-pixel CI, iOS/macOS, SQLite runtime,
  Shizuku/device, and Samsung S23 checks remain pending or not tested. Overall
  status remains `NOT RELEASE READY`.

## 2026-10-29 — Stage 5k: Build 22 fixture deduplication hardening

- **Workflow checkpoint:** `b58e086bd732084c65c897b1d9f740eb9b6c9e85`
  (published on both `codex/foto-master-final-20261029` and `main`).
- The offline emulator fixture now creates distinct PNG bytes for 2020 and
  2024 by drawing the year into the edge content while keeping the center
  white. Local SHA-256 values differ (`0c18beb7…` and `d07788f3…`) and both
  center pixels are white, so server checksum deduplication cannot collapse
  the years into one timeline bucket.
- The workflow now asserts each upload returns `status=created` with an asset
  id before starting the offline replay. YAML parsing and the fixture pixel/
  checksum check PASS. Hosted Build 22 emulator execution remains pending.

## 2026-10-29 — Stage 5l: hosted Actions receipt recovered through GitHub web

- **Historical run:** `40886945546` on workflow commit `b58e086bd732` was read
  from the public GitHub Actions web pages despite the local `gh api` token
  returning HTTP 403. The run was later cancelled by a newer queued run; the
  completed job results remain factual.
- **PASS:** API contract tests (11/11) completed before infrastructure setup;
  Android durable thumbnail cache + CloudMedia/Shizuku policy job completed
  successfully; iOS Flutter analyze, service/repository tests, screenshot
  framing policy, rendered-pixel widget test, offline warmup and SQLite
  recovery fixture tests all completed successfully.
- **FAIL/BLOCKED:** disposable PostgreSQL/Redis pull failed in the API job and
  in both official Android jobs, so server startup and unchanged-client launch
  were not reached. This is an infrastructure pull failure, not a client
  compatibility result. The jobs did verify the official APK checksums and v2
  certificates first.
- **CANCELLED:** iOS simulator build and Build 22 offline process-death replay
  were cancelled by concurrency when a newer workflow request entered the
  queue. They are not PASS and are not treated as NOT TESTED.
- **Artifacts:** `foto-build22-offline-emulator` digest
  `sha256:9907bd51817f10bad06b1d88a830fae03d72a69e0c46c99752b69c0da6a752d6`;
  Android 5.8.0 receipt digest
  `sha256:a5265e9e1bc383d061d1b73290abf7c142d1d65106f277900af2b32fa56d212b`;
  Android 5.9.0 receipt digest
  `sha256:412e29ad2651bb856c4bcbdd016845554b68597c62b9a5017df2ca219fab6f2a`.
- **Final retry:** GHCR authentication was added in `1f27ec1f15af` with
  `packages: read`; final stabilized run `40890985422` is waiting on a hosted
  runner. No further heavy workflow was started after that push.

## 2026-10-29 — Stage 6: Build 22 P0 compatibility and Android gate repair

- **Checkpoint:** `c40b15395` on `codex/foto-build22-resume-20261029`; remote branch SHA verified.
- **Fact check:** public GitHub Actions run `40909759811` was re-read from GitHub web. `api-contract` is PASS; `ios-contract` is CANCELLED; `android-offline-cache` and `foto-offline-emulator` are FAIL; both stock Android 5.8.0 (`123575099353`) and 5.9.0 (`123575100102`) exhaust all retries at `phase=wait_login` with the exact server-version incompatibility message. The run is on `b216af2be0dd5867c45221724f9612afff62abb8`.
- **Root cause and fix:** official v5.8.0/v5.9.0 source accepts server major versions from `app.major` through `app.major + 1`. The disposable backend exposed the un-stamped `server/package.json` fallback `3.2.0`, so both unchanged 5.x clients rejected it before login. `e2e/docker-compose.yml` now passes the existing Docker `BUILD_VERSION=5.7.3` stamp, and the API smoke asserts `/api/server/version` is `5.7.3`. Original APKs remain byte-for-byte untouched.
- **Android smoke:** both emulator scripts now poll the UI hierarchy for a semantic text input (including compatible subclasses/input-type metadata), emit the current phase and UI summary on timeout, and no longer throw an uninformative `IndexError` when the field is not present. A fake no-field run exits explicitly at `server_endpoint_field`.
- **Gradle:** the hosted cache job and Build 22 debug build now bound heap to runner memory, cap heap at 6 GiB, disable parallel workers, disable the daemon for unit tests, and persist complete JVM/Kotlin daemon options through Gradle user properties for Flutter builds. Tests must still run; no assertions were disabled.
- **SQLite:** added a copy-only recovery operator and fixtures. It validates a captured DB/WAL/SHM snapshot, runs integrity and foreign-key checks, fingerprints user tables including pending operations, only attempts named-index `REINDEX` on a proven index-only failure, writes a redacted receipt, and never promotes a candidate. Flutter execution remains pending because this Cloud image has no Dart/Flutter runtime.
- **Verification:** 12 server compatibility/API contract tests PASS; `pnpm --dir server build` PASS with 79 Gallery migrations and compatibility aliases; version-stamp unit probe PASS; Docker Compose config, shell syntax, Python/JSON checks and `git diff --check` PASS. Plugin WASM build is BLOCKED by missing pinned `extism-js`; hosted Android/iOS/device/HP/NAS gates remain open.
- **Production:** unchanged. No HP, NAS, signing key, real user data or production service was accessed.
- **Next stage:** run one controlled hosted workflow on this exact published SHA, then inspect jobs/artifacts before continuing SQLite device replay, original-client full flows, and remaining product gates.

## 2026-10-29 — Stage 7: SQLite corruption recovery and deterministic Android actions

- **Source checkpoints:** `76f36de52a5abcdf42b2cbddb38207751c14f3e7` (P0 sync/recovery implementation) and `55e3b091e85a610f908c61aa6867b28a77891684` (stock-client semantic action flow); the branch remote head was verified at the latter SHA.
- **SQLite P0 implementation:** `updateAssetsV2` now halts on unsafe SQLite result `779`, lets the transaction roll back, captures a copy-only DB/WAL/SHM snapshot, preserves pending/cursor rows, and propagates `SqliteDatabaseUnhealthy` through service and background-sync gates. An explicit recovery release epoch clears stale worker-isolate gates only after validated copy recovery.
- **Reproducible fixture:** `mobile/test/infrastructure/repositories/sqlite_sync_recovery_file_test.dart` creates a file-backed Drift database, corrupts the production `UQ_remote_assets_owner_checksum` index, verifies the real `updateAssetsV2` failure and unchanged primary bytes, diagnoses and `REINDEX`s a copied candidate, then replays the same asset event on that candidate while asserting pending/cursor values survive. `sync_stream_service_test.dart` also verifies no ACK is sent after the corruption signal. The primary/device database is never reset or promoted by this code.
- **Android gate repair:** both emulator scripts now wait for focused text input, clear and read back URL/email with bounded retry, tolerate masked passwords, choose enabled semantic `Next`/`Login` actions, and use an IME fallback only when the endpoint action is absent. Disabled fields cannot advance the login gate.
- **Checks available in Cloud:** `git diff --check`, both smoke scripts with `bash -n`, Python release handoff tests (3/3) and static source review PASS. Flutter/Dart runtime is unavailable in this environment, so the new file-backed test awaits hosted execution.
- **Hosted evidence:** run `40937674495` on `76f36de52` passed API contract/backend smoke but its Android/FOTO jobs were cancelled by the superseding semantic-action checkpoint; no Android or SQLite runtime PASS is inferred. Run `40938640647` for `55e3b091e` is queued behind that cleanup and is the authoritative next gate.
- **Release status:** `NOT_RELEASE_READY`. Samsung S23, macOS/iOS runtime, production-signing APK, HP/NAS, production services and physical-device replay remain open. No production HP, Synology NAS, signing key, user data or primary SQLite database was changed.

## 2026-10-29 — Stage 8: Hosted P0 proof and bounded Build 22 launch diagnosis

- **SQLite P0 hosted proof:** run `40938640647` on `55e3b091e85a610f908c61aa6867b28a77891684` completed the iOS Flutter gate, including the real file-backed SQLite recovery fixture. The fixture reproduced corruption of `UQ_remote_assets_owner_checksum`, observed SQLite result `779`, preserved the primary bytes and pending/cursor settings after rollback, repaired only a copied candidate with `REINDEX`, and replayed the asset event on that candidate. The receipt keeps `promotionAllowed=false`.
- **Original clients:** the same run completed the unchanged official Android 5.8.0 and 5.9.0 emulator E2E jobs. Both clients accepted the stamped disposable backend (`5.7.3`); the earlier backend-version incompatibility is closed without changing either APK.
- **Build 22 failure evidence:** run `40945591027` on `52129624a0cc1bcf65bcc22ef096c49154b8a000` passed APK build, PostgreSQL/Redis, backend, seed fixture and KVM/ADB preparation. Its three emulator attempts reached `wait_for_boot`, `server_endpoint_dump` and `clear_and_launch`, then exited before the endpoint field; public annotations exposed no deeper shell log.
- **Bounded diagnosis fix:** checkpoint `99d4a58eabf6cc13f1f4e4fc3151cde051925b03` splits that phase into `clear_data` and `launch`, bounds `pm clear` to 15 seconds as disposable-emulator best effort, and keeps the launcher strict. Shell syntax, `git diff --check`, and Python release handoff tests (3/3) pass locally. Hosted verification is run `40950288472` on this exact SHA.
- **Release status:** remains `NOT_RELEASE_READY` until the new Build 22 smoke, macOS/iOS runtime packaging, Samsung S23, production signing, HP/NAS and production service gates are independently closed. No production HP, Synology NAS, signing key, user data or primary SQLite database was changed.

## 2026-10-29 — Stage 9: Build 22 hosted E2E closed on exact source SHA

- **Diagnostic checkpoint:** `a89bcb0c14aec952ea3377504905c1759c2425d2` added `ERR` inheritance, bounded `uiautomator dump` retries, stderr/error detection, XML hierarchy validation, atomic UI snapshots and an artifact dump log. Run `40956102162` proved the previously hidden failure: the API 35 media permission dialog (`Allow limited access` / `Allow all`) blocked the endpoint and authenticated UI. Its annotations provided phase and UI evidence without touching any real device.
- **Final fix:** `d9b64f1a15d5582f08fa5b9f8fd24c5062a5a552` grants the requested media permissions only to the disposable emulator package after `pm clear` and dismisses those exact semantic dialog labels before strict endpoint assertions. Both original-client and FOTO scripts carry the same bounded UI handling.
- **Exact-SHA hosted PASS:** run `40961734970` completed all jobs on `d9b64f1a…`: API contract/backend (`123755970160`), iOS analysis/service/repository/rendered tests and SQLite recovery fixture (`123755969746`), Android cache unit tests (`123755970070`), Build 22 APK/backend/seed/KVM and offline process-death replay (`123755969984`), and unchanged official Android 5.8.0 (`123755970131`) plus 5.9.0 (`123755969995`). The FOTO smoke reached credentials, login, endpoint and offline phases and completed successfully; no compatibility-version error or permission-dialog failure remained.
- **P0 SQLite state:** the file-backed hosted fixture remains PASS for real `SQLITE_CORRUPT_INDEX` result `779` in `updateAssetsV2`, rollback, pending/cursor preservation, copy-only `REINDEX`, promotion prohibition and replay on the repaired copy. No primary/device database was reset, replaced or promoted.
- **Release status:** `NOT_RELEASE_READY` still reflects unperformed production gates: Samsung S23 physical replay, production signing key/release artifact, HP/Synology/NAS validation and production-service operations. No production HP, Synology NAS, signing key or user data was changed.

## 2026-10-30 — Stage 10: final acceptance matrix and release handoff

- **Documentation checkpoint:** `aad9b91fd` records the exact 33-row master
  acceptance matrix, two supplemental P0 gates, the current release-gate ledger,
  `RELEASE_README.md`, and `release-manifest-20261030.json`.
- **Authoritative hosted evidence:** run `40961734970` is complete/successful;
  Build 22 emulator, API/backend, Android cache policy, iOS simulator/source and
  unchanged Android Noodle 5.8.0/5.9.0 jobs are all PASS. The file-backed
  SQLite fixture reproduces result `779` at `updateAssetsV2`, preserves pending
  operations/cursors, repairs only a copied candidate and resumes on that copy.
- **Focused source checks:** server duplicate/stack/trash suites report 87 passing
  tests; focused Web editor/live-photo/Places/motion suite reports 65 passing
  tests. Medium suites requiring a container runtime remain blocked before tests.
- **Release handoff:** package `de.opennoodle.gallery`, version `5.7.3+22`, and
  prior certificate `ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`
  are recorded. The old key is not present in Cloud, so the signed APK is
  `BLOCKED_OLD_KEY_HP_ONLY`; no replacement key was created or copied.
- **Open gates:** PR creation remains blocked by the configured HTTP 403 token;
  Samsung/Android 16 and physical iOS, HP/Synology/NFS and populated-restore
  checks, final Web/Chromium build, signed release artifact and production
  operations remain open. Overall status stays `NOT_RELEASE_READY`.
