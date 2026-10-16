# Build 11 Codex CLI delivery report

Date: 2026-10-16  
Source commit: `d12ebedd1e3cbc2d223fe5e63b898023e9a4d6f0`  
Branch: `codex/nas-release-readiness-20261016`  
PR: https://github.com/docice545/gallery/pull/1 (open, draft)

This report records the deliverables that were actually produced from the CLI
checkout. It does not authorize a merge, deployment, queue change, NAS access,
or deletion of real media.

## Deliverables

| Deliverable                          | Result           | Evidence                                                                                                                                                                                                 |
| ------------------------------------ | ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Backend Docker image                 | **DONE locally** | `gallery-server:trash-d12ebedd1e3c`, image digest `sha256:68da3feb7da24cf0744ff21849f3510649c1e1de086c21d2b99e59f16b1448ab`, source commit above, `linux/amd64`                                          |
| Backend export                       | **DONE locally** | `/mnt/hp-data/codex-work/gallery-auto/20261016-073302-3497099/backend-artifact-1792138825/gallery-server-linux-amd64.tar.gz`, SHA-256 `e13fdb84b60964c8383d8ad7667a0ea91f6aec5ff86c62de02273e9af7d73070` |
| Web frontend                         | **DONE locally** | `BUILD11_web_build.log`; production build completed successfully; web lint passed in `BUILD11_web_lint.log`                                                                                              |
| Android APK                          | **BLOCKED**      | Local Gradle reached `:app:compileDebugAidl` and then blocked on HTTPS Google/Android dependency resolution; no APK was created                                                                          |
| Registry/GitHub artifact publication | **BLOCKED**      | No registry credentials or authenticated `gh` session are available in this CLI environment                                                                                                              |

The backend image was built from a clean detached worktree and inspected for
architecture, source revision, packaged server version, `server/dist/main.js`,
and both fork migration additions. Deployment is recorded as `NOT_DEPLOYED`.

## Verification

- `python3 -m unittest scripts/release/tests/test_gallery_install.py`: 18 passed.
- `python3 -m unittest scripts/release/tests/test_android_release.py`: 35 passed.
- `python3 -m py_compile` for release tooling: passed.
- `git diff --check`: passed.
- Backend build with the required heap increase: passed.
- Web build and web lint: passed.
- Flutter code generation and focused Live Photo test: passed (5/5).
- Direct AIDL smoke compilation with Android Build Tools 36: passed.

The full disposable 1/10/100/1000 performance matrix, real Synology/NFS
validation, and complete storage integration/e2e suite were not run. Existing
synthetic deletion evidence remains synthetic and is not evidence of a real NAS.

## Android and CI blocker

The repository contains a manual `Gallery Build Mobile` workflow with the
`android_media_pilot` validation lane. GitHub API inspection found no run for
this source commit and no current APK artifact. The local `gh` client reports
that it is unauthenticated, so this checkout cannot dispatch or download that
workflow. A future authorized CI run must use this exact commit and retain the
validation APK, versionName/versionCode, and SHA-256 before Android can be
marked complete.

No production signing material was read or created, and no debug APK is being
claimed.
