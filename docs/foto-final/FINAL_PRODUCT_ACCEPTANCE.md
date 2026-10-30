# FOTO Build 22 acceptance matrix

Continuation baseline: `0b0e924b75b2e3417dd3a35a96771b94b15fc69f`.
Validated source and CI definition: `0719bf7042d128b09a3591f3a084af1edf2b5ae6`.
The following documentation commit does not change product code. Package
`de.opennoodle.gallery` and version `5.7.3+22` are preserved.

`PASS` is qualified by the evidence actually available. Local results below
were obtained with Flutter 3.47.2, Node 24.21.0 and locked dependencies. Hosted
results belong to their run's `headSha`: use [the exact-checkout gate commands](RELEASE_GATES.md)
to retrieve the final compatibility and web runs together. A queued run is not a pass.
The physical/production release remains **NOT RELEASE READY**.

## Current source validation

- Flutter analyzer: no issues. All 21 diagnostics from the baseline iOS job
  were fixed without weakening analysis or changing index repair semantics.
- SQLite: 15 real-file/gate tests pass, including 779, WAL-only pending rows,
  incomplete/damaged WAL rejection, unchanged primary bytes and copy-only repair.
- Feature regression selection: 1962 Flutter tests pass across 66 test paths
  (including the complete existing `test/services` and `test/repositories`
  directories). Coverage includes editor/Magic Eraser routes, save-copy/retry,
  history, Live Photo, Places/localization, Trash/Stacks, CloudMedia SQL and UI,
  Memories geometry, screenshot framing, offline warmup and Drift migrations.
- Backend: 263 tests in eight focused suites pass (Magic Eraser, Stack, Trash,
  Duplicate, Memories). Four real PostgreSQL suites pass all 67 tests; 175
  migrations executed on a new disposable test database. This is clean-db
  evidence, not a populated HP upgrade or rollback rehearsal.
- Web: 78 tests in six focused suites pass (editor, Live Photo, Places, Trash
  authorization/page and ten-locale string parity).

## Product matrix

|   # | Area                              | Evidence / status                                                                                          | Remaining acceptance                                                         |
| --: | --------------------------------- | ---------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
|   1 | Git integration                   | PASS: resumed published baseline; small additive commits, no force-push/reset/merge                        | Pin HP build to final published SHA; no PR merge is required by this handoff |
|   2 | Offline catalogue/timeline        | PASS: existing source, local regressions; baseline hosted FOTO replay passed                               | Samsung offline library replay                                               |
|   3 | Persistent thumbnail cache/warmup | PASS: local policy tests; baseline hosted cache and offline replay passed                                  | Real storage pressure/eviction                                               |
|   4 | Wi-Fi/cellular/reconnect          | PASS: warmup policy and hosted offline replay                                                              | Physical transport switching, account rotation                               |
|   5 | SQLite recovery                   | PASS: 15 local tests and strict hosted fixture gate; see [recovery details](SQLITE_CORRUPTION_RECOVERY.md) | Power loss, full storage, device/operator restore                            |
|   6 | CloudMediaProvider                | PASS: existing provider/source, actual SQL against Drift schema, Kotlin CI gate                            | Android 16/Samsung runtime                                                   |
|   7 | Shizuku admission/undo/isolation  | PASS: caller/session gates, journal-before-write, read-back, owned undo; Kotlin CI gate                    | Real grant/deny/revoke/undo and Android user switching                       |
|   8 | Samsung Gallery / One UI          | NOT TESTED physically                                                                                      | Samsung S23/One UI                                                           |
|   9 | System Photo Picker               | PASS: source/catalog/privacy tests and existing emulator dialog handling                                   | OEM selection, account/ACL revocation, full-size media reads                 |
|  10 | MediaStore/SAF/share/Trash        | PASS: source/repository policy tests                                                                       | Device permission/expiry/retry reconciliation                                |
|  11 | Android Live/Motion Photo         | PASS: pairing/import, thumbnail/controller/scope tests; API pairing smoke gate                             | Samsung codec/playback/export and NAS sidecars                               |
|  12 | iOS Live Photo                    | PASS: source/service contracts; unsigned simulator build is a hosted gate                                  | PhotoKit, physical iPhone, original iOS client                               |
|  13 | Web Live Photo                    | PASS: focused tests; production web/Chromium gates                                                         | Populated authenticated media playback fixtures                              |
|  14 | Places / MapLibre                 | PASS: repositories, picker/provider/widget tests                                                           | Installed-device map/geocoder and large library                              |
|  15 | Russian/local geodata             | PASS: name/search/identity/localization regressions                                                        | Runtime geocoder/map labels                                                  |
|  16 | Compact editor                    | PASS: route/layout/geometry/markup/history/save-copy/retry tests                                           | Installed APK visual and file-save acceptance                                |
|  17 | Magic Eraser / Big-LaMa           | PASS: local mobile/backend contracts; previous isolated cloud inference retained as historical evidence    | HP staging service/model integration and latency                             |
|  18 | Trash/restore/sync ACK            | PASS: mobile tests, PostgreSQL retention tests and hosted API smoke gate                                   | MediaStore pending work, expiry and restart                                  |
|  19 | Stack selection/deletion          | PASS: local mobile + real PostgreSQL maintenance/selection suites                                          | Device replay with existing external maintenance                             |
|  20 | `chudo_anna` duplicate pairs      | NOT TESTED on HP/NAS                                                                                       | Owner-approved read-only inventory; completed Takeout migration stays closed |
|  21 | All-owner duplicate audit         | PASS: generic owner-scoped test fixtures; NOT TESTED on real library                                       | Read-only HP/NAS inventory, no production delete/apply                       |
|  22 | Empty Trash 10/100/500/1000       | PASS: source and retention regressions                                                                     | Disposable NFS benchmark; no production empty-trash benchmark                |
|  23 | Synology / External Library       | Source retained; physical integration NOT TESTED                                                           | NFS permissions, disconnect/reconnect, read-only originals, sidecars         |
|  24 | Managed assets/storage safety     | PASS: guarded backend source/tests                                                                         | HP volume layout and backup consistency                                      |
|  25 | Albums/Faces/Memories/ownership   | PASS: API/sync contracts, CloudMedia SQL ownership, widget tests                                           | Full client/device/NAS isolation acceptance                                  |
|  26 | Original Noodle compatibility     | PASS at baseline for unchanged Android 5.8/5.9; both rerun in final gate                                   | Original iOS device acceptance remains separate                              |
|  27 | PostgreSQL migrations             | PASS: disposable fresh DB (175 migrations)                                                                 | Restore populated HP backup and rehearse upgrade before approval             |
|  28 | Backend Docker image              | PASS at baseline disposable CI; final workflow rebuilds image                                              | Owner builds/deploys immutable HP image                                      |
|  29 | Web build/browser                 | Historical production build/Chromium pass; final full web workflow required by SHA                         | Chromium slice is `reskin-computed`, not full authenticated E2E              |
|  30 | Android release signing           | HP ONLY                                                                                                    | Existing certificate, release APK and Build 21 → 22 update                   |
|  31 | Backup/rollback                   | Copy-only SQLite verified; [owner runbook](RELEASE_README.md) prepared                                     | Actual HP restore and device data backup/recovery                            |
|  32 | Samsung/iPhone acceptance         | NOT TESTED physically                                                                                      | Installed signed APK and physical iPhone                                     |
|  33 | Production switch                 | **NOT RELEASE READY**                                                                                      | Explicit owner decision after HP/device gates                                |

The portrait Memories lane and horizontal scrolling are preserved; its two
widget tests pass. The stale failure text in earlier versions of this matrix
was superseded by baseline run [41052091513](https://github.com/docice545/gallery/actions/runs/41052091513)
and the local continuation tests. Geometry was not redesigned.

Baseline compatibility run [41052091521](https://github.com/docice545/gallery/actions/runs/41052091521)
passed API, both stock Android versions, durable cache and FOTO offline E2E.
Its only failed job was iOS analysis; subsequent test groups ran with `pipefail`
and passed. The 21 analyzer diagnostics are now fixed. The old claims about
invalid GitHub auth and swallowed pipeline exits are obsolete.

CloudMediaProvider remains the existing implementation. It reads the current
account's catalog, filters owner/partner/space visibility, scopes IDs to the
session, revalidates server ACL/trash before opening media and rechecks the
session during reads. Tests are not evidence of successful OEM admission.
No HP connection, NAS inventory, production signing, migration or deployment
was performed by this continuation.
