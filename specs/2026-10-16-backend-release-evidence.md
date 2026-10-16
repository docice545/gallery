# Backend release evidence — 2026-10-16

This record covers the historical deletion-job cleanup endpoints and the bounded
`AssetDeleteBatch` worker. All destructive checks used disposable PostgreSQL and
filesystem fixtures. Production Compose, production PostgreSQL/Redis/storage, VPN,
NAS mounts, and real photographs were not accessed.

## Checks

| Check                                 | Result  | Evidence                                                                                                                                                                                                                                                                                          |
| ------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Targeted backend tests                | PASS    | `server`: 4 files, 287 tests; queue controller, controller registry, job repository, and asset service                                                                                                                                                                                            |
| TypeScript check                      | PASS    | `cd server && pnpm check`                                                                                                                                                                                                                                                                         |
| Disposable batch matrix               | PASS    | `batch-matrix.jsonl`; 1/10/100 use the inline path, 1000 uses the bounded worker                                                                                                                                                                                                                  |
| Batch worker measurement              | PASS    | 1000 synthetic assets: 277170 ms, 3.608 assets/s, RSS delta -6381568 bytes                                                                                                                                                                                                                        |
| Historical-job audit/reconcile smoke  | PASS    | Isolated image smoke: authenticated audit and reconcile both returned HTTP 201 with zero synthetic jobs changed                                                                                                                                                                                   |
| Web Trash/delete regression           | PASS    | Vitest: 4 files, 28 tests; queued completion, cancellation, partial acknowledgement, preflight and Trash-page semantics                                                                                                                                                                           |
| Mobile Trash/delete regression        | PASS    | Flutter: 3 files, 26 tests; aggregate polling, reconciliation, explicit cancel and selection preservation                                                                                                                                                                                         |
| Web Empty Trash bounded flow          | PASS    | Gallery web snapshots the single owner Trash timeline and routes Empty Trash through shared preflight/batch polling; 3 focused suites, 23 tests                                                                                                                                                   |
| Original client Empty Trash contract  | PASS    | Server controller returns HTTP 200 `{count}` for `POST /api/trash/empty`; mobile repository regression confirms generated client delegation                                                                                                                                                       |
| Upstream wire-contract retention      | PASS    | `python3 scripts/release/upstream_compatibility.py --report /tmp/gallery-upstream-compat-20261016.json`: 371 retained operations, 97 upstream migrations byte-identical, zero failures                                                                                                            |
| Mobile version-warning regression     | PASS    | `flutter test test/modules/utils/version_compatibility_test.dart`: 7 tests passed; admin-only server-update warning and client/server incompatibility warning remain distinct                                                                                                                     |
| Android artifact inspection           | PARTIAL | Existing local release APK is package `de.opennoodle.gallery`, version `5.7.3`, versionCode `11`, SHA-256 `0e294e9f5e77a29b856c37f8e9d71acb4736b6ec3439b16ba80dd06ea12d1286`, certificate `ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`; it cannot upgrade reported Build 12 |
| Original-client artifact availability | BLOCKED | No upstream/original APK or IPA was present in the checkout or task artifact directories. The available APK is a Gallery build only; no device or macOS signing/runtime tools are available.                                                                                                      |
| Real Synology/NFS validation          | BLOCKED | No separate disposable Synology test directory/export is available                                                                                                                                                                                                                                |

The 1/10/100 rows report `elapsedMs=0` for the batch worker because those requests
remain intentionally inline and do not invoke the worker. They are correctness
fixtures, not HTTP latency measurements. The 1000 row verified complete durable
receipts and absence of every synthetic original file. A separate 401-item
interruption/recovery run stopped after the first 200-item chunk and resumed with
the same payload; all receipts completed and all synthetic files were removed.

## Safety boundary

`POST /api/queues/deletion-jobs/audit` is read-only. The reconcile endpoint removes
only obsolete, non-active BullMQ metadata and never invokes a deletion handler or
touches assets, receipts, originals, derivatives, NAS paths, or retention state.
Historical requests are never replayed. Current deletion requests retain the
owner-scoped preflight, durable receipts, advisory lock, Live Photo pairing, and
idempotent retry protocol.

The disposable Docker image used for the isolated smoke was
`gallery-server:autocodex-20261016` with local manifest digest
`sha256:a54af0beb186cd5af257b59befe6c11f05e8a995d86b866bdd36e08b66cc6897`.
It was removed after the smoke; no registry publication or production deployment
was performed.

## Remaining release gates

- Real Synology/NFS validation remains pending until an explicitly separate test
  export is available.
- Aggregate batch status/progress is implemented in this stage: large deletion
  responses include a deterministic owner-scoped `batchId`, and
  `GET /api/assets/permanent-deletion/status?batchId=...` reports aggregate
  complete/failed/pending counts from BullMQ plus durable receipts. Completed
  and failed batch metadata is retained for seven days for refresh/recovery.
  Cancellation is implemented as an owner-scoped durable stop request: the
  worker checks it before each bounded 200-item chunk, leaves already-started
  work to finish, and reports `cancelled`/`cancelRequested` without undoing
  completed deletion.
- Web asset-viewer, selection, timeline and gallery paths all use the same
  acknowledgement-vs-completion flow. Mobile Empty Trash captures one owner
  snapshot, shows aggregate progress, supports explicit cancellation after a
  `batchId`, and reconciles only confirmed `complete` receipts. A cancelled
  selection is not implicitly retried.
- Gallery web Empty Trash now captures the loaded owner-scoped Trash timeline as
  one bounded snapshot and calls that same deletion flow. The legacy
  `POST /api/trash/empty` endpoint remains available for original clients but is
  no longer called by Gallery web; this preserves the upstream contract while
  preventing the web UI from treating a count-only acknowledgement as physical
  completion. An empty snapshot performs no mutation.
- The original-client compatibility surface remains covered by contract tests:
  the server still accepts `POST /api/trash/empty` and returns the unchanged
  `TrashResponseDto { count }` shape with HTTP 200, while the generated mobile
  client delegates to that endpoint. This is Android/iOS SDK contract evidence;
  no original APK or IPA was executed in this environment.
- The read-only structural gate retained all 371 operations from the verified
  upstream base (`da5480ae42b77db9cae729f2447ec9b3079ba4a7`) and all 97 upstream
  migration files byte-for-byte. Its report is explicitly limited to wire
  shape and migration-source retention; it does not certify authentication,
  uploads, sync, albums, Live Photos, or runtime behavior of an original client.
- The Android warning behavior required for Build 12 continuity is present in
  the current history: server-version metadata stamping (`0e376fdf5`), hidden
  stale/latest-version warnings (`855817514c4`, `e5156df4f1b9`), and the
  account-scoped cloud admission recovery (`2348266a6`) are all ancestors of
  this branch. The focused version-warning suite passed 7 tests, including
  preserving real server-update and incompatible-client warnings.
- This is contract/regression evidence, not real-client compatibility evidence.
  No upstream Android APK or iOS IPA was run against this server; no device
  upgrade, signed Build >=13, or iOS archive was produced in this stage.
- The locally retained release APK from an earlier Build 11 run is
  `/mnt/hp-data/codex-work/gallery-auto/20261016-100448-3611623/artifacts/Foto.apk`
  (package `de.opennoodle.gallery`, version `5.7.3`, versionCode `11`, SHA-256
  `0e294e9f5e77a29b856c37f8e9d71acb4736b6ec3439b16ba80dd06ea12d1286`, signer
  `ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`). It is
  not an upgrade artifact for the reported installed Build 12 and is not
  attributed to the current commit. The checkout has no `key.jks` or
  `key.properties`, so producing the authorized `foto` Build >=13 remains
  blocked pending the existing signing environment and approval.
- The 2026-10-16 artifact availability audit searched the checkout and all task
  artifact directories for `*.apk`, `*.aab` and `*.ipa`. It found only Gallery
  outputs and the retained Build 11 copies. The current release output reports
  package `de.opennoodle.gallery`, version `5.7.3`, versionCode `11`, and
  SHA-256 `0e294e9f5e77a29b856c37f8e9d71acb4736b6ec3439b16ba80dd06ea12d1286`;
  `apksigner verify --verbose --print-certs` passes APK Signature Scheme v2 and
  reports certificate
  `ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
  This is inspection of a locally produced Gallery artifact, not an upstream
  client compatibility run, and its provenance is not attributed to the current
  commit. No `adb`, `xcrun` or `codesign` executable is available, so no Android
  install, iOS build, IPA inspection or real-client against-server run was
  attempted.
- Production audit, deployment, and any cleanup of production queue metadata
  require a separate explicit operational step.

## Latest validation stage (2026-10-16)

- Remote branch synchronization was read-only with respect to repository history:
  `c9f8a3de647b1aee6f35dcf653f20bdbf345b9e8` was already an ancestor, and the
  current candidate `8788ae89f5dd9aac64d30f9a13b232c0ceeee7ed` was pushed without
  force-updating or discarding the working tree. Existing untracked `BUILD*.log`
  files remain outside Git.
- Structural compatibility was rerun with
  `python3 scripts/release/upstream_compatibility.py`: 371 retained operations,
  97 byte-identical upstream migrations, zero failures. This remains a wire
  contract gate only; it does not claim original-client runtime compatibility.
- Focused server checks passed: `pnpm check` and the trash/job controller suites
  (2 files, 70 tests). Focused web checks passed: 3 Vitest suites (23 tests),
  TypeScript check, and Svelte check with zero errors/warnings. Focused mobile
  checks passed: 4 Flutter suites (32 tests) and Dart analysis with no issues.
- The original Android/iOS gate is still BLOCKED. No upstream APK or IPA,
  Android device runtime, macOS/Xcode toolchain, authorized `foto` signing
  files, or separate disposable NFS export is available in this environment.
  The inspected Gallery Build 11 remains versionCode 11 and cannot prove an
  upgrade over the reported installed Build 12. No APK was installed and no
  production, NAS, VPN, Redis, or real-media operation was performed.

## Final branch synchronization stage (2026-10-16)

- `git fetch origin codex/nas-release-readiness-20261016` confirmed the remote
  instruction tip `c9f8a3de647b1aee6f35dcf653f20bdbf345b9e8` is an ancestor of
  the candidate branch. The complete candidate `0e282b7070182fb0a6aff771924a3b62d993c77a`
  was pushed without reset, force-update, or working-tree cleanup; `git
ls-remote` reports the same remote HEAD.
- The artifact audit remains unchanged after synchronization: only Gallery
  APKs were found in the checkout/task artifact directories, no upstream APK or
  IPA is available, and no Android device, macOS/Xcode toolchain, or authorized
  `foto` signing files are present. Real-client compatibility and signed
  versionCode >=13 therefore remain BLOCKED rather than being inferred from
  contract tests or the Gallery Build 11 inspection.
- Existing untracked `BUILD*.log` files remain preserved outside Git. No APK was
  installed and no production, NAS, VPN, Redis, or real-media operation was
  performed.

## Compatibility and signing audit stage (2026-10-16)

- The immutable structural gate was rerun at candidate HEAD
  `4c6462e91b2ee25ae7f8e6d801b5f6105cf1d967`: 371 retained upstream operations,
  97 byte-identical migrations, and zero failures. The report still limits its
  claim to wire-contract/source retention.
- `python3 -m unittest scripts.release.tests.test_upstream_compatibility
scripts.release.tests.test_build11_artifacts` passed 27 tests, and
  `python3 -m unittest discover -s mobile/scripts/tests -p
'test_ios_build_only.py'` passed 33 tests. Focused runtime checks also passed:
  server trash/job controllers (75 tests), web TypeScript, and mobile version/
  original-trash contract tests (14 tests).
- A read-only search across `/mnt/hp-data` found no original upstream Android
  APK, iOS IPA, or AAB. Only Gallery APKs and the retained Gallery Build 11
  artifact were present. No Android device/runtime, macOS/Xcode toolchain,
  `adb`, `xcrun`, or `codesign` is available. No `mobile/android/key.jks`,
  `key.properties`, or signing environment variables are present.
- The mandatory original-client runtime matrix (auth/session, uploads,
  albums/sync, Live Photo, and trash/restore) therefore remains **BLOCKED**;
  contract and structural tests do not substitute for executing the original
  APK/IPA. A signed `foto` Android artifact with versionCode >=13 also remains
  **BLOCKED**. No APK was installed and no production, NAS, VPN, Redis, or
  real-media operation was performed.

## Focused Vitest rerun stage (2026-10-16)

- The earlier timed-out invocation used the wrong `pnpm test -- --run` form and
  an unsupported Vitest 4 `--minWorkers` option. It did not provide a test result.
- The server queue-controller regression passed with the supported isolated
  invocation:
  `cd server && pnpm exec vitest --config test/vitest.config.mjs --run src/controllers/queue.controller.spec.ts --pool=forks --maxWorkers=1 --no-file-parallelism --reporter=verbose`
  — 1 file, 3 tests.
- The web trash-authorization regression passed with:
  `cd web && pnpm exec vitest --run src/lib/services/trash-authorization.spec.ts --pool=forks --maxWorkers=1 --no-file-parallelism --reporter=verbose`
  — 1 file, 3 tests.
- `git diff --check` passed and no Vitest processes remained after the runs.
  These focused results do not change the real-NAS, original-client, or signed
  Android release gates above.

## Disposable NFS preflight stage (2026-10-17)

- Read-only host preflight confirmed Docker, `findmnt`, and `ss` are available;
  `127.0.0.1:2295` is free and no `gallery_nfs_test_*` containers or
  `gallery_nfs_test` network exist.
- The exact disposable source is mounted at `/mnt/gallery-nfs-test` as
  `10.10.10.95:/volume1/Gallery-Test`, but `findmnt` reports `ro`. The harness
  therefore fails closed and was not started. No Compose container, database,
  Redis queue, fixture, or NAS file was created or changed.
- `bash -n deployment/gallery-nfs-test/scripts/preflight.sh deployment/gallery-nfs-test/scripts/run-live-photo-test.sh`
  passed. The disposable NFS lifecycle remains **BLOCKED** pending an owner-side
  RW remount of that exact export; production mounts and the Synology recycle
  directory were not accessed.

## AI and automatic-stack audit stage (2026-10-17)

- Read-only source audit found no LiteLLM, `memories-vision`, Groq, or Cloudflare
  vision client in Gallery. The external-memory audit states that Gallery does
  not hold those credentials or perform provider calls; therefore Groq-primary
  and Cloudflare-fallback behavior, preview sanitization, and cloud quota remain
  **BLOCKED for runtime verification** and were not simulated with private media.
- Gallery retains memory lifecycle, owner/deduplication, and candidate tests, but
  the `gallery-ai-daily`/carousel scheduler is external infrastructure. No daily
  generation, historical rerun, or production memory mutation was performed.
- The stack compatibility suite covers native API mutations, owner boundaries,
  suppression decisions, dissolution without asset deletion, and Motion Photo
  preservation. The production design records the external hourly processor and
  thresholds (0.90 similarity, 0.89 pairwise floor, 300 seconds, max 5) and
  Anna's exclusion. The external processor itself was not run, so grouping,
  Android position display, and scheduler survival remain **BLOCKED** for
  runtime acceptance.
