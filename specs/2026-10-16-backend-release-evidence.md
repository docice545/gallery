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
- The exact disposable source is visible at `/mnt/gallery-nfs-test` as
  `10.10.10.95:/volume1/Gallery-Test`. Mount-namespace evidence distinguishes
  the cause: `/proc/self/mountinfo` reports the mount's per-mount options as
  `ro`, while the NFS superblock options on that line report `rw`. This
  establishes that this executor's mount view is locally read-only; it does not
  establish that the NAS export is read-only. The session has no effective
  capabilities, `NoNewPrivs: 1`, and cannot remount it (`mount.nfs` rejects the
  unprivileged remount). `/etc/fstab` contains no Gallery-Test entry, and the
  session cannot inspect the host-side executor launch configuration, so the
  exact host setting that applied the read-only bind mount remains unverified.
- Safe remediation: have the HP executor/runtime expose only this exact
  disposable mount to the test executor with a read-write bind mount, retaining
  existing NAS export rules and keeping production/archive mounts read-only or
  absent. Recreate the executor mount namespace through normal host-side
  configuration; do not attempt an in-session remount or edit `/etc/fstab` or
  NAS export rules. Verify the exact source and visible per-mount `rw` option
  before running the harness.
- The harness therefore failed closed and was not started. No Compose
  container, database, Redis queue, fixture, or NAS file was created or
  changed. `bash -n deployment/gallery-nfs-test/scripts/preflight.sh
  deployment/gallery-nfs-test/scripts/run-live-photo-test.sh` passed. The
  disposable NFS lifecycle remains **BLOCKED** pending a runtime-side RW bind
  mount for this exact disposable path; production mounts and the Synology
  recycle directory were not accessed.

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
  and scheduler survival remain **BLOCKED** for runtime acceptance. Android's
  asset viewer now renders the selected stack index and local stack length as
  `N/total`; focused Flutter tests cover one-based formatting, a stale index,
  and an empty stack. This verifies the numeric indicator logic, not device-level
  visual behavior or automatic grouping.

## Isolated disposable Synology NFS lifecycle stage (2026-10-17)

- The isolated preflight passed against the exact source `10.10.10.95:/volume1/Gallery-Test`, with the dedicated Compose project `gallery-nfs-test`, server bound only to `127.0.0.1:2295`, and no production paths, networks, containers, Redis, databases, or archive mounts included.
- The first run stopped safely at admin setup because the disposable database already contained an admin from an earlier isolated run; it created no media fixture. Reusing the recorded disposable account then completed the full API lifecycle with a fresh synthetic nonce.
- **PASS:** actual Gallery upload produced a linked Live Photo pair: JPG row `c5f52b1a-b388-4b89-9f35-458a2914499e` under `/data/upload` backed by the disposable NFS mount, and MP4 row `9cdf18a3-0f79-4fd9-b8ae-b115fddf3c55` under `/data/encoded-video` backed by the dedicated SSD directory. Database pairing (`livePhotoVideoId`) and both physical placements were checked before mutation.
- **PASS:** trash, restore, repeated restore (idempotency), second trash, explicit managed-deletion consent, and permanent purge completed. Final checks found zero rows for both synthetic IDs and neither synthetic file remained on NFS or SSD. Only the current disposable owner's fixture was addressed.
- The tested local image was `gallery-server:nfs-f1b1d1f`, image ID/digest `sha256:0669fc1b9aaa4b0008796311775941d0a78b47372433cc6da2c6d58488b8f57e`; no registry publication or production deployment occurred. Evidence log: `/tmp/gallery-nfs-live-photo-20261017-rerun2.log`; retained fixture diagnostics: `/mnt/hp-data/gallery-nfs-test/media/fixture.urbswk`.
- This is a real isolated NFS-mounted test, but it does not certify DSM recycle-bin semantics, production NAS behavior, upstream original-client compatibility, AI provider fallback, external auto-stack scheduling, or signed Android upgrade packaging.

## PR synchronization and Memory/Stack focused rerun (2026-10-17)

- The isolated-NFS evidence was committed as `f213d09654a4564842cfa353362789988f047335` and pushed to `codex/nas-release-readiness-20261016`. GitHub API readback confirms PR `https://github.com/docice545/gallery/pull/1` is open and its head is this exact commit.
- **PASS:** `server/src/services/memory.service.spec.ts` — 104 tests passed with the isolated Vitest invocation (`pnpm exec vitest --config test/vitest.config.mjs --run src/services/memory.service.spec.ts --pool=forks --maxWorkers=1 --no-file-parallelism --reporter=dot`).
- **PASS:** `server/src/services/stack.service.spec.ts` — 22 tests passed with the same isolated Vitest settings. These tests cover native stack behavior and do not execute the external hourly maintenance process.
- These reruns add repository-level regression evidence only. External `gallery-ai-daily`, LiteLLM/Groq/Cloudflare, and `noodle-gallery-maintenance` runtime behavior remains outside this executor and therefore **BLOCKED** for runtime acceptance.

## Local release artifact gate (2026-10-17)

- **PASS:** backend production build from HEAD `891764a26eb2bf1563130c8b5619defbf5a019fd` with `cd server && NODE_OPTIONS=--max-old-space-size=3072 pnpm build`. The build completed and `sync-gallery-migrations.mjs` copied 73 Gallery migrations, removed one stale compiled copy, and wrote both compatibility aliases. The ordinary heap setting previously OOMed; the larger heap is a local build requirement, not a runtime change.
- **PASS:** web production build with `cd web && pnpm build`; Svelte production output was written to `web/build`. The build reports the existing unresolved runtime WASM URL and large-chunk advisories; neither is a build failure. `pnpm check:svelte && pnpm check:typescript` completed with zero diagnostics, and `cd server && pnpm check` completed successfully.
- **PASS:** a reproducible local Docker image was built from this checkout with `docker build -f server/Dockerfile -t gallery-server:release-891764a26 --build-arg BUILD_VERSION=5.7.3 --build-arg BUILD_ID=local-20261017 --build-arg BUILD_SOURCE_REF=codex/nas-release-readiness-20261016 --build-arg BUILD_SOURCE_COMMIT=891764a26eb2bf1563130c8b5619defbf5a019fd .` The local image is `gallery-server:release-891764a26`, manifest digest `sha256:9cb61a78da7784e466003603a6e6b5759ee951aba6df942875e4d59cecb0c061`, size 622,166,460 bytes. A network-disabled container check reported application version `5.7.3` and the exact source commit/ref. No registry publication or deployment was performed.
- This artifact gate does not close original Android/iOS runtime compatibility, signed Android versionCode >=13 with the authorized `foto` identity, external AI provider fallback, external AI Memories/maintenance scheduling, automatic-stack grouping, or DSM recycle-bin semantics; those remain **BLOCKED** pending the required external clients, signing environment, and external services.

## Android packaging rerun (2026-10-17)

- **PASS (unsigned-for-upgrade artifact):** from source `95048b2d851c916efde39b3a73f31e2b876cec0b`,
  `cd mobile && /mnt/hp-data/codex-toolchain/flutter/bin/flutter build apk --release --build-name=5.7.3 --build-number=13`
  completed successfully in 523.1 seconds. The ignored output is
  `mobile/build/app/outputs/flutter-apk/app-release.apk`, package
  `de.opennoodle.gallery`, version `5.7.3`, versionCode `13`, compile/target SDK
  `36`, SHA-256
  `cef0dcaacfffe504db9fabe6f1a705c9803bbcc7a03d707719e36cba7eeae9c5`.
- `apksigner verify --verbose --print-certs` passed APK Signature Scheme v2, but
  identified the Android debug certificate
  `dbf29cc8789f8c9321846726d08eb93a906dbc4228c72787c02831d738014624` rather
  than the authorized `foto` certificate
  `ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
- This proves a reproducible versionCode 13 package and metadata only. It is
  **not** an upgrade artifact for the installed Build 12 and was not installed;
  the signed `foto` Build >=13 gate remains **BLOCKED** because the keystore,
  device and upgrade environment are unavailable in this executor.

## Final release-readiness matrix (2026-10-17)

| Gate | Result | Evidence and limit |
| ---- | ------ | ------------------ |
| Backend build and type check | **PASS** | `server` production build with the documented 3072 MiB local heap and `pnpm check`. |
| Web build and type checks | **PASS** | `web pnpm build`, Svelte check, and TypeScript check completed with zero diagnostics. Existing WASM URL/chunk advisories remain. |
| Docker artifact | **PASS (local)** | `gallery-server:release-891764a26`, digest `sha256:9cb61a78da7784e466003603a6e6b5759ee951aba6df942875e4d59cecb0c061`; registry publication was not available or attempted. |
| Trash and deletion contracts | **PASS** | Server, web, and mobile focused suites pass; one owner-scoped Trash flow, durable batch status, cancellation, receipts, and legacy original-client endpoint are covered. |
| Disposable NFS Live Photo lifecycle | **PASS** | Isolated `10.10.10.95:/volume1/Gallery-Test` run covered JPG-on-NFS plus paired MP4-on-SSD, trash, restore, idempotent restore, consent, and purge. DSM `#recycle` behavior and production NAS remain unverified. |
| Bulk deletion performance | **PARTIAL** | 1000 synthetic worker items completed in 277170 ms (3.608 assets/s); 1/10/100 rows are inline correctness fixtures with `elapsedMs=0`, not HTTP latency. The required mixed-media 1/10/100/1000 wall-clock/NFS load matrix is incomplete. |
| Android package continuity | **PARTIAL** | Reproducible release APK has package `de.opennoodle.gallery`, version `5.7.3`, versionCode `13`, SDK 36, SHA-256 `cef0dcaacfffe504db9fabe6f1a705c9803bbcc7a03d707719e36cba7eeae9c5`. It is debug-signed and cannot upgrade the installed `foto` Build 12. |
| Original Android/iOS runtime compatibility | **BLOCKED** | No representative upstream APK/IPA, Android device, or macOS/Xcode runtime is available. Structural wire-contract retention is not a runtime-client test. |
| AI Memories daily scheduler | **BLOCKED** | `gallery-ai-daily` is external; no authorized synthetic endpoint or scheduler run is available. Gallery lifecycle tests do not prove delivery, limits, or rejection-after-delete. |
| Groq → Cloudflare fallback | **BLOCKED** | Provider clients, credentials, and a safe test endpoint are external to this checkout; no private media was sent. |
| Automatic stack grouping | **BLOCKED** | Native Stack API and unit tests pass, but the external maintenance processor, hourly scheduling, survival, and Anna exclusion were not run. |
| Signed `foto` Android upgrade | **BLOCKED** | Existing keystore/signing environment and device are unavailable; the debug certificate does not match the authorized certificate. |
| Artifact publication and deployment | **BLOCKED/PENDING** | Docker image and APK remain local; no registry/store publication, merge, or deployment was authorized or performed. |

**Readiness assessment: NOT READY for a production release.** The local code,
tests, isolated NFS lifecycle, and reproducible artifacts are suitable for review,
but the blocked client, signing, external-AI, automatic-stack, and complete
performance gates are acceptance requirements rather than optional follow-up.

## Safe delivery and rollback notes

The local Docker artifact is review-only until it is published through the
existing release workflow. A release operator must first create a database dump
and preserve the complete `UPLOAD_LOCATION` (including `encoded-video`,
`library`, `thumbs`, `upload`, and backups), then deploy an immutable image
digest and verify `/api/server/version` and health before enabling external jobs.
Do not use a floating tag for a release record.

If validation fails, stop the new services, restore the database backup using
the documented [backup and restore procedure](/administration/backup-and-restore),
restore the matching media snapshot, and pin the previously known-good image
digest. A downgrade has not been tested or promised; schema rollback requires a
database restore and the matching media state. External AI and maintenance
jobs must remain disabled until the restored server has passed its health and
version checks. These instructions were documented only; no production rollback
or deployment was executed in this stage.

## Metadata extraction race follow-up (2026-10-17)

The isolated harness was rechecked against the running image
`gallery-server:nfs-f1b1d1f` before rebuilding the candidate. Preflight passed
with the exact `10.10.10.95:/volume1/Gallery-Test` NFS source, `rw` mount, private
Compose networks, dedicated SSD paths, and loopback-only port `2295`. The
image's upload/refresh sequence reproduced a metadata race: the synthetic JPG
was present on NFS and remained in the isolated database, but no
`livePhotoVideoId` was created after the metadata job retried. No production
container, archive mount, or `#recycle` path was accessed, and no permanent
deletion was attempted in this follow-up.

The candidate now assigns `AssetExtractMetadata` a stable per-asset BullMQ
`jobId` with `removeOnComplete` and `removeOnFail`, so upload-triggered and
explicit refresh jobs coalesce while allowing a later retry after failure.
The regression test and full server type check pass at commit
`4c37b946e` (`job.repository.spec.ts`: 68 tests; `pnpm check`: exit 0).
The existing NFS image has not been rebuilt with this fix yet, so a new image
and an end-to-end rerun are required before the candidate can claim fresh NFS
PASS evidence. The synthetic orphan fixture remains confined to the disposable
test stack and is not production media.
