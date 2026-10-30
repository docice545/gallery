# FOTO Build 22 release gates

This is the current gate ledger for the published branch
`codex/foto-build22-resume-20261029`, ending at
`314f65373fe9a48ee5e187b4f06b4a69de478279`. Web acceptance passed in
[run 41002023786](https://github.com/docice545/gallery/actions/runs/41002023786).
The retry-hardened exact-head compatibility run is
[41004224774](https://github.com/docice545/gallery/actions/runs/41004224774).

| Gate | Status | Evidence | Remaining condition |
|---|---|---|---|
| Git source/checkpoint | PASS | Remote branch SHA `314f65373fe9a48ee5e187b4f06b4a69de478279`; no force-push or history rewrite | Keep release artifact tied to this source |
| GitHub PR integration | BLOCKED (Cloud auth) | Branch is published; prior `gh pr create` returned HTTP 403 with invalid `GH_TOKEN` | Restore authorized GitHub token or use the compare URL; no merge was performed |
| API contract/backend | PASS | [API job 123755970160](https://github.com/docice545/gallery/actions/runs/40961734970/job/123755970160) | Populated upgrade/NAS staging remains separate |
| Disposable PostgreSQL/Redis | PASS | Same API/FOTO jobs; pinned images and GHCR auth | Populated upgrade and restore benchmark remain open |
| Official Noodle Android 5.8.0 | PASS | [job 123755970131](https://github.com/docice545/gallery/actions/runs/40961734970/job/123755970131) | No production install performed |
| Official Noodle Android 5.9.0 | PASS | [job 123755969995](https://github.com/docice545/gallery/actions/runs/40961734970/job/123755969995) | No production install performed |
| FOTO Build 22 debug APK/offline process death | PASS | [job 123755969984](https://github.com/docice545/gallery/actions/runs/40961734970/job/123755969984) | Debug emulator APK is not the signed release APK |
| Android cache/CloudMedia policy tests | PASS | [job 123755970070](https://github.com/docice545/gallery/actions/runs/40961734970/job/123755970070) | Shizuku/Android 16/Samsung runtime remains open |
| iOS Flutter/source/simulator | UNRESOLVED | Run 41000215760 built the simulator app and Memories test, but its annotations reported 3/5, 0/1 and 10/2 failed tests; shell pipelines omit `pipefail` | Fix/classify failed groups and require a strict rerun; this is not an original iOS TestFlight/device E2E |
| SQLite `SQLITE_CORRUPT_INDEX` recovery | PASS | Hosted file-backed fixture in iOS job: result 779, rollback, pending/cursor preservation, copy-only repair and replay | Physical device replay still requires approved device |
| Screenshot framing | PASS (hosted) | Rendered-pixel tests plus final FOTO emulator run | Samsung visual acceptance open |
| Offline gray-screen recovery | PASS (hosted) | Durable cache tests plus final process-death/offline emulator run | Device/account-rotation matrix open |
| Editor/Live Photo/Places/Trash/Stacks | PASS (source/API tests) | Focused source suites and hosted API/FOTO gates | Physical codec, MediaStore, map and editor acceptance open |
| Duplicates/NAS/External Library | BLOCKED | Read-only tools and guarded backend tests exist | Owner-approved HP/Synology inventory required |
| Empty-Trash scale benchmark | PASS (source) / BLOCKED (HP/NFS) | Server regression coverage | Disposable NFS/HP benchmark required |
| Big-LaMa/Magic Eraser | PASS (isolated cloud Docker) / BLOCKED (HP) | Pinned model SHA, 55 tests + 1 env skip, real model inference and authenticated container `/inpaint` passed | Staging inference on approved HP required |
| Memories lane carousel | FAIL (hosted widget command; source fix published) / PIXEL COMPARISON OPEN | iOS job `123884087117` of run `41000215760` reported `0 tests passed, 1 failed`; unauthenticated log view exposes no failure body; supplied reference images were unavailable in workspace | Diagnose/fix the widget test, run it with strict exit propagation, then run screenshot/golden comparison |
| Web build/Chromium E2E | PASS (hosted deterministic slice) | Run 41002023786, jobs `123888388605` and `123888388822`: production build, type checks, Web Vitest and disposable-backend Chromium slice passed | Broader authenticated media fixture suite remains separate |
| Android production release APK | BLOCKED | No `key.jks`, `key.properties`, or release secrets in Cloud | Owner runs HP procedure with existing `foto` key |
| Samsung S23 / Android 16 | BLOCKED | No physical device in Cloud | Synthetic test account/device approval required |
| Physical iPhone/original iOS client | BLOCKED | macOS simulator build only | Physical iPhone/TestFlight acceptance required |
| Backup/rollback/NAS production switch | BLOCKED | Source runbooks and non-destructive code | Owner-approved staging and rollback only |
| Overall Build 22 release | **NOT RELEASE READY** | Mandatory HP/device/signing gates remain open | Do not deploy or publish production APK |

The previous failures are retained as diagnosis, not hidden: run
`40956102162` exposed the missing `ERR` receipt, run `40950288472` exposed the
Android 35 photo permission dialog, and run `41000215760` exposed a transient
GHCR dependency-start failure in the 5.8.0 matrix child. Retry/cleanup
hardening is published in `314f65373`; no production HP, Synology NAS, user
data, signing key or primary SQLite database was changed.
