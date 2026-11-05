# FOTO Build 22 release gates

Source/CI checkpoint: `0719bf7042d128b09a3591f3a084af1edf2b5ae6` on
`codex/foto-build22-resume-20261029`. Local checks are complete. Final hosted
verdicts are stored by GitHub against the exact published checkout, including
this handoff. Do not substitute an older successful run or a debug APK for a
release/device gate. **NOT RELEASE READY** remains the overall verdict.

## Resolve the final hosted receipts

Run from the checkout selected for the HP build. Both workflows must report
`completed / success` for the same `headSha` as `git rev-parse HEAD`:

```bash
foto_sha=$(git rev-parse HEAD)
for foto_workflow in original-noodle-gallery-compatibility.yml foto-build22-web-acceptance.yml; do
  gh run list --repo docice545/gallery --commit "$foto_sha" \
    --workflow "$foto_workflow" --limit 10 \
    --json headSha,status,conclusion,url \
    --jq '.[] | {headSha,status,conclusion,url}'
done
```

Receipts are accessible through [compatibility Actions](https://github.com/docice545/gallery/actions/workflows/original-noodle-gallery-compatibility.yml?query=branch%3Acodex%2Ffoto-build22-resume-20261029)
and [web Actions](https://github.com/docice545/gallery/actions/workflows/foto-build22-web-acceptance.yml?query=branch%3Acodex%2Ffoto-build22-resume-20261029).
The final delivery includes the resolved run URLs and published SHA. A missing,
queued, cancelled or failed run leaves that hosted gate open.

| Gate                              | Evidence and requirement                                                                                          | Open boundary                                                                        |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Flutter analysis                  | Local PASS, zero issues; strict final iOS job must also pass                                                      | No analyzer exclusions or severity changes                                           |
| SQLite recovery                   | Local PASS, 15 tests; same files in strict iOS job                                                                | Physical recovery/low-storage/crash matrix                                           |
| Existing Flutter features         | Local PASS, 1962 selected tests                                                                                   | Physical editor, maps, MediaStore, codecs                                            |
| Memories portrait lane            | Local PASS, 2 widget tests; included in iOS job                                                                   | Visual comparison on installed APK                                                   |
| Screenshot framing/offline warmup | Local PASS; strict iOS test groups + FOTO emulator gate                                                           | Samsung visual/network/storage matrix                                                |
| Live Photo timeline               | Local PASS, 74 tests; all three suites added to iOS job                                                           | Physical remote/local playback/export                                                |
| Android cache/CloudMedia          | Final Kotlin job must pass cache, admission, MIME and range tests                                                 | Real Shizuku/Photo Picker/Android user lifecycle                                     |
| Android media policies            | Five existing Kotlin suites added to final gate: HTTP errors, Motion layout, Trash, Places, MIME                  | Native runtime is not certified by JVM tests                                         |
| API/backend compatibility         | Local contracts unchanged; final API/Docker/smoke job must pass                                                   | Populated upgrade and HP/NAS                                                         |
| Stock Android 5.8.0 and 5.9.0     | Both unchanged official APK matrix children must pass                                                             | Original iOS device client remains untested                                          |
| FOTO offline emulator             | Final debug APK → online sync → process death → offline relaunch must pass                                        | Release signature/physical device                                                    |
| iOS source/simulator              | Final strict analyzer/tests and unsigned simulator build must pass                                                | No physical/TestFlight/original iOS E2E claim                                        |
| Backend features/migrations       | Local PASS: 263 unit + 67 real PostgreSQL tests, 175 fresh migrations                                             | HP restored-data upgrade; no new server migration in this continuation               |
| Web                               | Local PASS: 78 focused tests; final workflow requires production build, TS/Svelte, full Vitest and Chromium slice | Authenticated media fixture E2E is broader than `reskin-computed`                    |
| Magic Eraser inference            | Prior isolated cloud model/inference evidence retained; mobile/backend tests pass locally                         | HP existing model/service staging required                                           |
| Git provenance                    | Branch continuation; final normal push and exact SHA receipts                                                     | No merge/production publishing implied                                               |
| Release APK                       | HP builds with existing `foto` identity                                                                           | Certificate, package/version and update acceptance                                   |
| HP PostgreSQL / backups           | Owner runbook prepared                                                                                            | Verified dump restore, populated migration rehearsal and explicit migration approval |
| Synology/NFS/dedup/scale          | Guarded source + synthetic fixtures                                                                               | Owner-approved read-only inventory and disposable benchmarks                         |
| Samsung/iPhone                    | Open physical gates                                                                                               | Build 21 → 22 app-data preservation and full checklist                               |
| Production rollout                | **NOT RELEASE READY**                                                                                             | Owner approval after every applicable HP/device gate                                 |

## Provenance and corrections

The starting SHA was confirmed remotely as
`0b0e924b75b2e3417dd3a35a96771b94b15fc69f`. Its compatibility run
[41052091521](https://github.com/docice545/gallery/actions/runs/41052091521)
passed every job except iOS analysis. The full authenticated log showed exactly
21 diagnostics in three SQLite test files. Service/repository tests (351),
framing policy (15), rendered framing (12), Memories (2), warmup (4), SQLite
fixtures (9) and the unsigned simulator build succeeded in that failed job.
These historical counts are not the new WAL regression count or a final-SHA pass.

The continuation fixes those diagnostics, rejects incomplete/corrupt WAL
snapshots instead of certifying an older SQLite view, and updates an obsolete
Live Photo thumbnail assertion to the remote-pair playback already implemented
in `abcf9c341`. No existing Memories/editor/provider/backend implementation was
replaced. GitHub authentication worked for remote, logs and workflow operations;
the old PR-token blocker is not a current release gate.
