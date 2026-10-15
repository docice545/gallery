# Build 11 — checkpoint 2026-10-13

## Completed
- Backend build successful (prior checkpoint), 71 Gallery migrations and 2 compatibility aliases.
- Web Svelte check: 0 errors, 0 warnings (prior checkpoint).
- Web lint passed (`BUILD11_web_lint.log`).
- Web production build passed; adapter-static wrote `web/build` (`BUILD11_web_build.log`).
- Signed-recovery proof tests passed: 1 file, 7 tests (`BUILD11_server_recovery.log`).

## Next
- Python release tests.
- Mobile checks and Android release artifact.
- Rootless isolated smoke if feasible, then artifact manifest and final report.

## Git status

Preserve all existing changes. No production deployment.

## Artifact audit stage — 2026-10-13

- Release Python syntax and `git diff --check` passed; existing Python release log records 146 tests passed and 10 skipped.
- No backend/mobile release artifacts or candidate profile exist locally. Artifact work therefore requires explicit successful CI runs and downloaded `gallery-server-linux-amd64.tar.gz`, `app-release.apk`, and `Photos-unsigned.ipa`.
- Build 11 proof must provide all workflow inputs (`source_commit`, `backend_run`, `android_run`, `ios_run`); do not use historical workflow defaults. Seal and hash `candidate-profile.json`, then pass its SHA-256 to frozen-bundle verification.
- Candidate profile contract is version 2, source-bound, server/mobile `5.7.2`, mobile build `9`, additive migration `1793600000000-AddAuthorizedAssetDeletion`, isolated smoke PASS, and immutable artifact/run IDs and SHA-256 values. Final `release-manifest.json` plus `SHA256SUMS` are generated only after those checks.
- `BUILD11_server_build.log` ends in Node OOM; it is not a successful build. No isolated Docker smoke was run locally.

## Verification stage — 2026-10-13 (continued)

- Server type-check passed: `cd server && NODE_OPTIONS=--max-old-space-size=1024 pnpm run check`.
- Server focused deletion/recovery suite passed: 3 files, 56 tests (`BUILD11_server_focused.log`).
- Server production build passed sequentially with `NODE_OPTIONS=--max-old-space-size=3072 pnpm run build` (`BUILD11_server_build_3072.log`). Postbuild synced 71 Gallery migrations, removed 1 stale copy, and wrote both compatibility aliases (`1776735180298-ChangeDurationToInteger` and `1777667825574-ChangeDurationToInteger`).
- The earlier 1024-MB build failure (`BUILD11_server_build.log`) was a Node heap OOM; it is superseded by the successful 3072-MB build.
- Python release suite re-run passed: 146 tests, 10 skipped (`BUILD11_python_release_tests_rerun.log`); `git diff --check` passed.
- Mobile focused tests were attempted twice with pinned Flutter 3.47.2. Initial run failed because generated OpenAPI/Pigeon/translation symbols were absent. Direct OpenAPI generation succeeded (`BUILD11_openapi_dart_codegen.log`), but the rerun still failed at library loading because the checkout lacks generated `StaticTranslations`, `NativeSyncApi`, `LivePhotoApi`, and related Pigeon/translation outputs (`BUILD11_mobile_focused_after_codegen.log`). No mobile source files were changed by generation.
- `mise //mobile:codegen` was unavailable in this environment because the installed mise did not recognize the repository monorepo root; the direct OpenAPI generator was used instead.
- No backend/mobile release artifacts, candidate profile, frozen bundle, or isolated Docker smoke were created. Production was not accessed or modified.

## Next

- Obtain/execute source-bound CI backend, Android, and iOS artifact runs, then verify the frozen bundle and generate the final release manifest. Do not use historical Build 8 workflow defaults.
- Resolve the mobile generated-output/tooling issue in a checkout with the full codegen prerequisites, then rerun focused tests.

## HP + Cloud integration stage — 2026-10-13

- Git state checked: local branch `fix/gallery-final-p1-cli` at `dcc78926fbd89ffcf1a8f8ccc4702859a135166b`; Cloud target `3e2cef4beec1b6f6cd267b7f2b384e59a016dc66`.
- Cloud target contains local HEAD as an ancestor; this is a linear continuation, not a divergent merge.
- Cloud handoff read from target commit. Cloud component CI succeeded (backend/iOS/Android), but distribution proof run `38385050973` failed at containerd/package/lab access; package is NOT READY. Cloud source is `f26b46059726ca3c55c63c3ce1edde7e45d8404f`, version `5.7.3+11`; successful backend run `38379404888`, Android `38379958872`, iOS `38377576890`.
- Cloud-only history after local source includes CI/release tooling, migrations, tests, docs, and client changes through `3e2cef4b`; no production changes are authorized.
- Path audit found broad overlap with HP uncommitted changes, including i18n, mobile deletion/Live Photo files, release helpers, server deletion services/tests, and web settings. Blind merge is therefore disallowed.
- Existing verified local backup remains `/mnt/hp-data/codex-work/build11-backups/20261013T112810Z`; it was not recreated.
