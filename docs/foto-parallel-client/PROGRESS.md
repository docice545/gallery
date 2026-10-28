# FOTO parallel client acceptance

## Stage A — inventory (2026-10-28)

- Published base: `codex/foto-final-rc-20261028` at `4bd351510bba8750f0f54d8777523d6603a44fdd`.
- Historical offline base: `fix/foto-offline-library-20261027` at `2eb2816f94647587a60c9b0e014bfdb30152fa08`.
- Build 21 reported by HP: `57b79cf3a7f11960ead971ca8963d666cc6baa91`. It is not an ancestor of the published final RC; its parent is `e5c9fbb0af3dd7dd188f80620ce254881feeb5ca`.
- Working branch: `codex/foto-client-acceptance-20261028-alt`, created from the published final RC without changing another worktree.
- No HP, production database, NAS, Samsung, iOS device, signing material, or deployment was accessed.

The final RC already contains the client fixes that were absent from the Build 21 comparison: durable thumbnail warmup/cache, the Wi-Fi/cellular consent control, remote-only Android Live Photo selection/source handling, and their tests. The four-tool editor is present in both the Build 21 tree and final RC at this source SHA; a report that an APK shows the old editor therefore needs APK provenance/route evidence before another editor implementation is justified.

## Stage B — client regression checks (2026-10-28)

The final RC source was checked without changing application code. Focused Flutter checks passed (71 tests), Android JVM checks passed (9 suites / 91 tests), and Web Live Photo/component checks passed (49 tests). Scoped Flutter analysis, Web Svelte diagnostics, ESLint, Prettier, and the Web production build passed. Whole-tree Flutter analysis is blocked by missing/unsupported generated fixtures; see `specs/audits/foto-client-acceptance-2026-10.md`.

The editor source is already four-tool in both Build 21 and final RC. Its reported absence in the installed APK remains an APK provenance or runtime-route question and cannot be closed from Cloud source inspection.

## Current gate state

| Area | Cloud source/tests | Hardware or production evidence |
|---|---|---|
| Offline Drift catalogue and warmup | **PASS** — focused source tests | Samsung cold-start/airplane-mode scroll **BLOCKED** |
| Persistent thumbnail cache | **PASS** — Android JVM cache/endpoint tests | cache restore and storage pressure on Samsung **BLOCKED** |
| Wi-Fi/cellular warmup setting | **PASS** — focused source tests | real settings path/data warning on Samsung **BLOCKED** |
| Android Live Photo, local and remote | **PASS** — focused source tests, including remote paired motion | decoded frames on Samsung **BLOCKED** |
| Web Live Photo | **PASS** — 49 targeted tests, typecheck/lint/format/build | Chromium with real media **NOT TESTED** |
| Places/Russian labels | restored source/tests recorded | HP geodata/native tiles/Geocoder **BLOCKED** |
| Four-tool editor/Magic Eraser | **SOURCE PRESENT** — editor unchanged between Build 21 and final RC | APK route and Samsung/iOS UI **BLOCKED**; HP inference **BLOCKED** |
| Noodle Gallery Android/iOS compatibility | source/API audit only | unmodified clients against backend **NOT TESTED** |
| PostgreSQL/NAS/migrations/production | read-only source audit only | HP disposable DB/NFS and production **BLOCKED** |
| Overall release | **NOT RELEASE READY** | mandatory real-device, APK provenance, browser, iOS and HP gates open |

## Evidence report

See `specs/audits/foto-client-acceptance-2026-10.md` for the exact commit comparison, commands, test counts, blockers, and safe HP/device protocol.

## Resume protocol

Preserve the archive and status before any new source change. Do not cherry-pick from the actively edited offline WIP branch until its compile and native tests are green. Do not claim hardware or upstream-client compatibility from unit tests.
