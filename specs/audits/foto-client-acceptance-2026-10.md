# FOTO client acceptance audit (2026-10-28)

This audit is for the independent client acceptance branch created from the published final RC. It records source and isolated test evidence only. No APK was built or installed, no production service was contacted, and no HP/NAS/phone/iOS device was accessed.

## Fixed source line and provenance

- Repository: `docice545/gallery`.
- Published final RC: `codex/foto-final-rc-20261028` at `4bd351510bba8750f0f54d8777523d6603a44fdd`.
- Acceptance branch: `codex/foto-client-acceptance-20261028-alt`.
- Build 21 reported by HP: `57b79cf3a7f11960ead971ca8963d666cc6baa91`, parent `e5c9fbb0af3dd7dd188f80620ce254881feeb5ca`.
- Historical offline branch checkpoint: `2eb2816f94647587a60c9b0e014bfdb30152fa08`.
- Draft PR #11 remains a separate historical line (`e2a95e6aeee9d9da8d23ca7643a6a061c61944c3`); it was not used as the acceptance base.
- The branch contains only the acceptance inventory/audit documents on top of the final RC. No application source was changed because the requested client fixes are already present in that RC.

`git diff 57b79cf3a7f11960ead971ca8963d666cc6baa91 4bd351510bba8750f0f54d8777523d6603a44fdd` shows that Build 21 missed these final-RC commits:

- `463fa72ed` — start offline thumbnail warmup from local timeline data;
- `d2d55004f` — expose Wi-Fi/cellular consent for thumbnail warmup;
- `abcf9c341`, `5c5ff638b`, `3d416f9da` — remote-only Live Photo candidate, source, and timeline preview;
- `f0908e9da`, `31ffd3596` — remote Live Photo regression coverage;
- `489f5e32d` — warmup diagnostics without personal asset data;
- `27605a42d`, `ede766e29` — persistent thumbnail cache across endpoint changes and its tests;
- `2eb2816f9`, `c20f66f5d`, `6663dcec3`, `58330fb1e`, `ed425f9e7`, `4bd351510` — settings/documentation/checkpoint commits.

The source-level explanation for three Build 21 reports is now precise: the Build 21 source checkpoint is an ancestor, but it predates the 16 final-RC commits that add the missing fixes. Whether the installed APK was actually built from that checkpoint still requires its binary/build receipt. The editor report needs separate APK provenance evidence: `mobile/lib/presentation/pages/edit/edit.page.dart` is byte-identical at Build 21 and final RC and already exposes crop, markup, text, and Magic Eraser modes. The repository `pubspec.yaml` also declares `5.7.3+19` while Gradle takes `versionCode` from `flutter.versionCode`; the reported Build 21 `versionCode=21` was supplied by an external build override and is not reproducible from this source without the original build command.

## Client feature inventory

| Feature | Implementation in final RC | Isolated evidence | Device/production gate |
|---|---|---|---|
| Offline catalogue and warmup | `OfflineThumbnailWarmup` starts from local Drift timeline data, paginates remote metadata, and observes network consent; `RemoteImagesImpl` uses durable `OfflineThumbnailCache` | 71 focused Flutter tests; 6 cache JVM tests | Samsung cold start, airplane mode, old-year scroll **BLOCKED** |
| Persistent thumbnails | Account/endpoint/auth-scoped thumbnail keys, bounded cache, image-header validation, endpoint-switch survival; originals and video are excluded | Android JVM suite includes cache, endpoint switch and invalid data cases | Samsung restart/storage pressure **BLOCKED** |
| Wi-Fi/cellular setting | Separate thumbnail warmup policy with explicit mobile-data consent and localized warning; it does not alter backup policy | Focused Flutter tests cover policy and consent | Real settings path and traffic warning on Samsung **BLOCKED** |
| Android Live Photo | Timeline scope/controller limits one active lease, settles viewport, stops on scroll/background/route changes, and accepts a verified remote paired motion component as well as a local component | 71 focused Flutter tests, including local cold start, remote pair, merged local source, unavailable local video, one-active/no-cascade | Decoded frames on Samsung **BLOCKED** |
| Web Live Photo | Existing shared pool and component tests enforce one automatic player, center/visibility choice, scroll settling, tab/route cleanup and no cascade | 49 targeted Vitest tests; Svelte check, lint, format and production build pass | Real Chromium media playback **NOT TESTED** |
| Places and Russian labels | Existing MapLibre style/localized label expressions, GPS-bound camera fit, clustering, place-name policy/cache and fallback | Place policy JVM tests included in Android suite | Production geodata, native tile rendering and Samsung UI **BLOCKED** |
| Editor/Magic Eraser | Existing four primary modes in `edit.page.dart`; Magic Eraser route/repository and save-as-copy are present | Source inspection; no new editor code was needed | APK route, Samsung UI, inpainting container and original preservation **BLOCKED** |
| Upstream Noodle Gallery Android | No client modification; source/API audit only | No official APK or test account in Cloud | Unmodified client against fixed backend **NOT TESTED** |
| Upstream Noodle Gallery iOS | No client modification; source/API audit only | No iOS device or signed app in Cloud | Unmodified client against fixed backend **NOT TESTED** |
| Backend, PostgreSQL, NAS and migrations | No changes in this branch | Git/source audit only | Disposable HP DB/NFS and production read-only checks **BLOCKED** |

## Automated checks

All commands were run in the acceptance worktree. Generated OpenAPI/Drift/Pigeon outputs were supplied from the existing ignored generated-output cache solely to make the source tests runnable; they are not committed.

| Check | Result | Evidence |
|---|---|---|
| Focused Flutter tests: offline warmup, autoplay controller, timeline scope | **PASS** — 71 tests, 0 failures | `/tmp/foto-client-rc-flutter-focused.log` |
| Scoped Flutter analyze over `lib` and the three focused test files | **PASS** — no issues | `/tmp/foto-client-rc-scoped-analyze.log` |
| Android JVM `:app:testDebugUnitTest` | **PASS** — 9 suites, 91 tests, 0 failures/errors/skips | `mobile/build/app/test-results/testDebugUnitTest/` |
| Web Live Photo Vitest/component tests | **PASS** — 3 files, 49 tests | `/tmp/foto-client-rc-web-live.log` |
| Web `svelte-check` | **PASS** — 0 errors, 0 warnings | `/tmp/foto-client-rc-web-svelte-check.log` |
| Web ESLint for Live Photo files | **PASS** | `/tmp/foto-client-rc-web-eslint.log` |
| Web Prettier check | **PASS** | `/tmp/foto-client-rc-web-prettier.log` |
| Web production build (`vite build`) | **PASS** | `/tmp/foto-client-rc-web-build.log` |
| Whole-tree `flutter analyze --no-pub` | **BLOCKED** by generated fixture hygiene: OpenAPI generated tests import unavailable package `test`, and Drift migration fixtures `test/drift/main/generated/schema*.dart` are absent | Environment/source-layout blocker, not a tracked-source diagnostic |
| Android release APK, signing, update over Build 21 | **NOT TESTED** by instruction; no key or APK available in Cloud | HP-only |
| Samsung decoded media, offline cold start, network transition | **NOT TESTED** | Physical device required |
| Official Android/iOS Noodle Gallery E2E | **NOT TESTED** | Fixed upstream binaries, accounts and backend required |

## Release decision

Status: **NOT RELEASE READY**.

The final RC source contains the missing client fixes and passes all available isolated focused tests. Release criteria are still open because the reported Build 21 APK behavior cannot be confirmed from source alone, the whole-tree analyze input is not reproducible without clean generated fixtures, and no Samsung, iOS, real-browser-media, HP backend, production-like database/NFS, APK update/signature, or unmodified Noodle Gallery client check was available. This branch must not be deployed or presented as a verified release.

## Safe next checks on HP and devices

Use a disposable test account and a copy of the APK/signing metadata. Do not change production data, NAS originals, migrations, Docker or network infrastructure.

1. Record the installed APK SHA-256, manifest package/version, signing certificate digest, and `apkanalyzer` file list for Build 21 and the candidate. Confirm the candidate has `applicationId=de.opennoodle.gallery`, `versionCode > 21`, the previous certificate, and the expected editor/live-photo/offline classes.
2. On Samsung, test cold start with Wi-Fi and mobile data disabled, scroll to an old year, open a cached remote thumbnail and a local photo, then restore the network and verify catalog continuity. Toggle Networking → Offline thumbnail downloads between Wi-Fi and cellular and verify the warning and persisted setting.
3. On Samsung, test local, remote and merged Live Photo pairs while scrolling, backgrounding, opening the viewer, returning, and completing playback. Confirm at most one decoded timeline player and no network request for a cached local preview.
4. In a disposable browser profile, verify one automatic Web Live Photo, center-priority selection, scroll pause/350 ms settle, tab hide/show, route changes, component removal, and manual fullscreen playback.
5. Against a disposable backend/test account, run official unmodified Noodle Gallery Android and iOS flows for login, timeline, thumbnail/original/video, Live Photo, albums, search, metadata, map, delete/restore, and account switch. Capture HTTP status/schema traces without personal data.
6. Compare editor route and save-as-copy behavior, run Magic Eraser capability/error paths, and hash the original before/after to prove it remains unchanged.

No deployment, production migration, NAS cleanup, or APK installation is authorized by this audit.
