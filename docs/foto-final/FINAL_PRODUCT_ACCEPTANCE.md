# FOTO Build 22 final product acceptance matrix

`PASS` names the exact automated/source evidence that ran. `BLOCKED` means a
required owner-controlled device, key, HP/NAS or production permission is
absent. `NOT TESTED` means no claim is made.

Evidence baseline: current published branch head `314f65373fe9a48ee5e187b4f06b4a69de478279`.
Product source was last exercised by the exact hosted compatibility run
[41000215760](https://github.com/docice545/gallery/actions/runs/41000215760) at
`46a6172d44a95ed1ba73673efd587fe986ffd9d`; its FOTO emulator passed, while
the Memories widget command reported `0 tests passed, 1 failed` and the
official Android 5.8.0 matrix child stopped at transient PostgreSQL/Redis
image startup. The retry-hardened exact-head run
[41004224774](https://github.com/docice545/gallery/actions/runs/41004224774) is
the current final receipt. Web build and Chromium acceptance passed at
[41002023786](https://github.com/docice545/gallery/actions/runs/41002023786) on
`e37c4cbb9ab92e5fe11b723feaf5ce59102d3e88`.

| # | Acceptance area | Status | Evidence / open condition |
|---:|---|---|---|
| 1 | Git integration and provenance | PASS (branch) / BLOCKED (PR auth) | Remote branch SHA and exact-SHA hosted run are recorded; PR creation remains blocked by the configured 403 token |
| 2 | Offline catalogue/timeline | PASS | FOTO debug emulator online sync, force-stop and offline relaunch passed |
| 3 | Persistent thumbnail warmup/cache | PASS | Android cache unit tests and hosted offline replay passed |
| 4 | Wi-Fi/cellular/reconnect behavior | PASS (hosted) | Smoke disables transports, relaunches and renders local catalog; physical network matrix open |
| 5 | SQLite corruption recovery | PASS (hosted) | Real index corruption → 779 at `updateAssetsV2`; rollback, pending/cursor preservation, copy-only `REINDEX`, replay; no primary promotion |
| 6 | Android CloudMediaProvider | PASS (source/CI) / BLOCKED (device) | Kotlin policy/range/cache tests passed; Android 16/Samsung provider runtime is unavailable in Cloud |
| 7 | Shizuku admission/undo/isolation | PASS (source/CI) / BLOCKED (device) | CloudAdmission policy tests passed; real grant/deny/undo cycle remains device-gated |
| 8 | Samsung Gallery / One UI | NOT TESTED | Requires Samsung S23/One UI |
| 9 | Android system Photo Picker | PASS (dialog handling) / NOT TESTED (full integration) | API 35 permission dialog handled; full provider/account-isolation acceptance open |
| 10 | MediaStore/SAF/share/Trash confirmation | NOT TESTED on physical device | Source/API tests exist; MediaStore reconciliation requires device |
| 11 | Android Live/Motion Photo | PASS (source/API) / BLOCKED (device codec) | Pairing/admission tests pass; physical playback/NAS sidecars open |
| 12 | iOS Live Photo | SOURCE PRESENT / HOSTED CONTRACT TESTS UNRESOLVED / BLOCKED (device) | The iOS job built the simulator app, but its piped service/repository, thumbnail and Memories groups reported failures (3/5, 0/1, 10/2 and 0/1); PhotoKit device acceptance is also open |
| 13 | Web Live Photo | PASS (focused source + hosted browser wiring) / NOT TESTED (media fixture) | Focused Vitest suite passed; hosted production build and deterministic Chromium browser slice passed in run 41002023786; populated Live Photo fixture playback remains open |
| 14 | Places / MapLibre | PASS (source/unit) / BLOCKED (device) | Place provider/repository tests pass; map runtime and large-library behavior open |
| 15 | Russian geodata/local geocoder | PASS (source/unit) / BLOCKED (device) | Localization tests pass; physical geocoder/map rendering open |
| 16 | Compact editor | PASS (source/tests) / BLOCKED (installed APK) | Crop/drawing/text/history/Magic Eraser tests exist; physical editor route open |
| 17 | Magic Eraser / Big-LaMa | PASS (cloud isolated Docker) / BLOCKED (HP staging) | Pinned model SHA verified; 55 worker tests, real local model inference, health and authenticated container inference passed; approved HP staging remains required |
| 18 | Android Trash/restore/sync ACK | PASS (source/API/hosted) / BLOCKED (device) | API/FOTO flow passes; MediaStore expiry/retry requires device |
| 19 | Stack deletion/selection | PASS (source/medium) / BLOCKED (device) | Focused server/mobile stack tests pass; physical media replay is open |
| 20 | `chudo_anna` duplicate pairs | BLOCKED | Requires read-only HP/NAS inventory; no production access authorized |
| 21 | All-owner duplicate audit | BLOCKED | Same owner-approved read-only inventory requirement |
| 22 | Empty Trash scale 10/100/500/1000 | PASS (source) / BLOCKED (NFS/HP benchmark) | Server regression tests pass; NFS timing benchmark not run |
| 23 | Synology External Library/NFS safety | BLOCKED | No production NAS access; disposable NFS staging still required |
| 24 | Managed Assets/storage safety | PASS (source) / BLOCKED (HP storage) | Guarded paths/tests pass; HP storage validation open |
| 25 | Albums/Faces/Memories/ownership | PASS (API/sync/source) / BLOCKED (full isolation) | API/sync ownership tests pass; complete client/NAS isolation is open |
| 26 | Original Noodle compatibility (Android + iOS) | PASS (historical Android) / PENDING exact-head rerun / NOT TESTED (original iOS) | Historical exact-SHA run 40961734970 passed unchanged Android 5.8.0/5.9.0; run 41000215760 reached the 5.9.0 emulator and failed only the 5.8.0 disposable dependency startup; retry-hardened run 41004224774 is the final exact-head receipt; original iOS client E2E was not run |
| 27 | PostgreSQL migrations/upgrade | PASS (disposable clean) / BLOCKED (populated upgrade) | API/backend and migration sync pass; populated restore/upgrade open |
| 28 | Backend Docker image | PASS (hosted disposable) | FOTO/API jobs build/start pinned disposable backend |
| 29 | Web build and browser E2E | PASS (hosted build + Chromium slice) | Run 41002023786: production web build, TypeScript/Svelte checks, Web Vitest and disposable-backend Chromium `reskin-computed` acceptance passed; broad authenticated media fixture suite remains separate |
| 30 | Android release APK/signing | BLOCKED | Cloud has no old key/secrets or signed artifact; HP key procedure prepared |
| 31 | Backup/rollback | PASS (source) / BLOCKED (HP restore) | Copy-only SQLite and release runbooks pass source review; HP restore open |
| 32 | Real Samsung/iPhone acceptance | BLOCKED | Physical devices unavailable and production data cannot be touched |
| 33 | Production switch/deployment | NOT RELEASE READY | Requires owner approval after every open gate closes |

## Supplemental P0 gates (not part of the 33 required rows)

- **MEMORIES_LANE_CAROUSEL:** `FAIL (hosted widget command; source fix published)` — `CarouselView`
  was replaced with a fixed-height horizontal `ListView.separated` using stable
  portrait cards, edge peeks, adaptive width, title overflow handling, and
  geometry/drag tests in `mobile/test/presentation/widgets/memory/memory_lane_test.dart`.
  The hosted command in iOS job `123884087117` of run `41000215760` reported
  `0 tests passed, 1 failed`; the exact failure output is not exposed by the
  unauthenticated GitHub log view. Attached source screenshots were also not
  available in the workspace for a pixel-by-pixel comparison.

- **SCREENSHOT_THUMBNAIL_FRAMING:** `PASS (hosted)` — rendered-pixel fixture and
  final emulator evidence passed; Samsung visual acceptance remains part of row 8.
- **OFFLINE_GRAY_SCREEN_RECOVERY:** `PASS (hosted)` — durable cache, auth
  fallback, process-death and offline replay passed; device/account-rotation
  coverage remains open.

The iOS job's green shell steps do not certify the failed test groups above:
the workflow currently captures output with `tee` without `pipefail`. The
failure counts are retained as unresolved rather than promoted to PASS; a
follow-up CI hardening change must make those commands fail the job and fix or
explicitly classify the underlying tests.

## Release identity and safe signing handoff

- Package: `de.opennoodle.gallery`.
- Source version: `5.7.3+22` (version code must be greater than Build 21).
- Required existing certificate SHA-256:
  `ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
- Cloud status: no `key.jks`, `key.properties`, `KEY_JKS`, alias or passwords;
  no signed APK exists and no new key was generated.
- Owner procedure: use a clean HP worktree at the exact published SHA, verify
  Flutter 3.47.2/Java 17, run locked codegen/tests, build
  `flutter build apk --release --build-name=5.7.3 --build-number=22`, verify
  package/version/certificate/SHA-256 with `aapt`/`apksigner`, then only after
  explicit approval install with `adb install -r` over Build 21. Keep passwords
  local and never upload the keystore. Detailed read-only preflight is in
  [`specs/testing/2026-10-06-mobile-week-hp-free-pilot.md`](../../specs/testing/2026-10-06-mobile-week-hp-free-pilot.md).
