# FOTO Build 22 release gates

This is the current gate ledger for the published branch
`codex/foto-build22-resume-20261029`. The final hosted source verification is
[run 40961734970](https://github.com/docice545/gallery/actions/runs/40961734970)
on source commit `d9b64f1a15d5582f08fa5b9f8fd24c5062a5a552`; the branch now ends at
documentation checkpoint `aa15c6ce9b20fb65abf4534c21bf154777970d8c`.

| Gate | Status | Evidence | Remaining condition |
|---|---|---|---|
| Git source/checkpoint | PASS | Remote branch SHA `aa15c6ce9b20fb65abf4534c21bf154777970d8c`; tested source `d9b64f1a…` | Keep release artifact tied to this source |
| GitHub PR integration | BLOCKED (Cloud auth) | Branch is published; prior `gh pr create` returned HTTP 403 with invalid `GH_TOKEN` | Restore authorized GitHub token or use the compare URL; no merge was performed |
| API contract/backend | PASS | [API job 123755970160](https://github.com/docice545/gallery/actions/runs/40961734970/job/123755970160) | Populated upgrade/NAS staging remains separate |
| Disposable PostgreSQL/Redis | PASS | Same API/FOTO jobs; pinned images and GHCR auth | Populated upgrade and restore benchmark remain open |
| Official Noodle Android 5.8.0 | PASS | [job 123755970131](https://github.com/docice545/gallery/actions/runs/40961734970/job/123755970131) | No production install performed |
| Official Noodle Android 5.9.0 | PASS | [job 123755969995](https://github.com/docice545/gallery/actions/runs/40961734970/job/123755969995) | No production install performed |
| FOTO Build 22 debug APK/offline process death | PASS | [job 123755969984](https://github.com/docice545/gallery/actions/runs/40961734970/job/123755969984) | Debug emulator APK is not the signed release APK |
| Android cache/CloudMedia policy tests | PASS | [job 123755970070](https://github.com/docice545/gallery/actions/runs/40961734970/job/123755970070) | Shizuku/Android 16/Samsung runtime remains open |
| iOS Flutter/source/simulator | PASS | [job 123755969746](https://github.com/docice545/gallery/actions/runs/40961734970/job/123755969746) | This is not an original iOS TestFlight/device E2E |
| SQLite `SQLITE_CORRUPT_INDEX` recovery | PASS | Hosted file-backed fixture in iOS job: result 779, rollback, pending/cursor preservation, copy-only repair and replay | Physical device replay still requires approved device |
| Screenshot framing | PASS (hosted) | Rendered-pixel tests plus final FOTO emulator run | Samsung visual acceptance open |
| Offline gray-screen recovery | PASS (hosted) | Durable cache tests plus final process-death/offline emulator run | Device/account-rotation matrix open |
| Editor/Live Photo/Places/Trash/Stacks | PASS (source/API tests) | Focused source suites and hosted API/FOTO gates | Physical codec, MediaStore, map and editor acceptance open |
| Duplicates/NAS/External Library | BLOCKED | Read-only tools and guarded backend tests exist | Owner-approved HP/Synology inventory required |
| Empty-Trash scale benchmark | PASS (source) / BLOCKED (HP/NFS) | Server regression coverage | Disposable NFS/HP benchmark required |
| Big-LaMa/Magic Eraser | PASS (source/API) / BLOCKED (HP) | Inference integration tests/source | Staging inference on approved HP required |
| Web build/Chromium E2E | NOT TESTED on final hosted run | Focused web tests are available | Run final web build and browser E2E |
| Android production release APK | BLOCKED | No `key.jks`, `key.properties`, or release secrets in Cloud | Owner runs HP procedure with existing `foto` key |
| Samsung S23 / Android 16 | BLOCKED | No physical device in Cloud | Synthetic test account/device approval required |
| Physical iPhone/original iOS client | BLOCKED | macOS simulator build only | Physical iPhone/TestFlight acceptance required |
| Backup/rollback/NAS production switch | BLOCKED | Source runbooks and non-destructive code | Owner-approved staging and rollback only |
| Overall Build 22 release | **NOT RELEASE READY** | Mandatory HP/device/signing gates remain open | Do not deploy or publish production APK |

The previous failures are retained as diagnosis, not hidden: run
`40956102162` exposed the missing `ERR` receipt, and run `40950288472` exposed
the Android 35 photo permission dialog. Both were fixed before the final
successful run. No production HP, Synology NAS, user data, signing key or
primary SQLite database was changed.
