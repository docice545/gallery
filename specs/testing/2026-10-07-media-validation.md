# Media reliability: validation and handoff

## Current baseline

Development started at `75633fc0d0071c18d9e48ce1017e830d8556416d`, branch `work`,
with a clean worktree. Existing history, the sharp/face-aware timeline, Trash,
Library Card Registry, stacks, Memories, Share/Download and Magic Eraser were
preserved. Anna/chudo_anna's migration is complete and closed; no migration or
historical Memories warmup was run.

The six-workstream continuation resumed at
`329c8b08e7e213e4f53379f90679d96ad6c3815b`; all completed work and the report draft
were retained. New changes are separate logical commits. Final mobile handoff
version is **5.7.2 build 6**, advanced from build 5 without changing package IDs
or signing configuration.

The latest validation continuation resumed at
`04f2e1ecf6ccb8b460383ee8a3fd37bfafc50748`, with the Android timeline surface
fix already complete. That source and all earlier user commits were retained.
The subsequent release-tooling correction is
`17fc9ede3b934b76617e3c03f70109ff33d6d38b`; it changes build preparation, not app
playback, native identities, signing keys or production behavior.

## Live/Motion root cause and implementation

**NEEDS_PHYSICAL_S23_VALIDATION.** The reported device uses «Фото» 5.7.2 build
4/5. No failing S23 log or source-video metadata was provided. The earlier
`7b39a7f73b` correction is already in the baseline; it cannot be presented as a
new fix. A synthetic decoder test also cannot prove the S23's composition,
server codec or eligibility behavior.

Build provenance was checked separately: `7b39a7f73b3de28ae80bddd5e51be94c70c11f6d`
introduced `5.7.2+4`; `f0fefc352ba1c3a01d0a2d0b4954d020c334eb95` introduced
`5.7.2+5` and contains that fix. The documented build-5 repository line therefore
includes it. No saved HP build HEAD/APK SHA or historical Android artifact ties
the **installed** APK to that line. A CLI build-number override remains possible;
do not classify the observed device as OUTDATED_APK from its version alone.
The exact original build record or APK provenance is still needed.

The shared Flutter changes add bounded, anonymous stage logging and tests.
A subsequent real Android CI failure proved authenticated media opened without
playback progress. An additive widget regression then proved that the unready
timeline submitted zero `PlatformViewLayer`s: `Visibility.maintain(false)`
suppresses painting, while Android hybrid composition needs a painted SurfaceView.
The minimal Android-only timeline exception paints the native surface during
preparation; its native container is transparent before the first frame. Completion
or failure hides it, including failure before readiness. iOS and ordinary viewer
readiness presentation remain unchanged. No replacement player or autoplay
algorithm was introduced; the real decoder regression remains mandatory. The records separate
eligibility, native-view creation, authenticated paired source, accepted load,
native dimensions, play acknowledgement, actual position advance and completion.
They contain no media names/IDs, paths, URLs, credentials or pairing identifiers.

Only the selected asset uses the existing native player. The 80% threshold,
350 ms settling delay, meaningful viewport change, muted one-shot playback,
no cascade, scroll/navigation cancellation, face-aware geometry, tile × DPR
sizing and bounded 1440 px still sources are unchanged. No timeline originals
are requested. See [runtime verification](2026-10-07-live-motion-runtime-check.md)
for the exact source path and physical acceptance steps.

## Cloud Media Provider

**IMPLEMENTED; NEEDS_PHYSICAL_S23_VALIDATION.** `GalleryCloudMediaProvider` is a
real Android system-provider implementation, enabled only on API 35+ and only
after explicit opt-in for the current authenticated account. The existing Drift
38 database supplies the catalog; the existing native session, HTTP/cookie and
certificate machinery supplies authenticated reads. There is no library REST
crawl, new server API, database migration, media mirror or MediaStore placeholder.

The canonical projection excludes Trash, Locked, archived/hidden media, hidden
Live/Motion companions, personally hidden Shared Spaces and inaccessible owners;
it preserves permitted partner/Space access and stack-primary behavior. Current
server ACL/visibility is rechecked when opening media. Account-scoped IDs and
enabled state prevent old picker IDs from opening under another account.

Pages are bounded at 200. A streamed digest versions the full collection after
changes, including deletions/restore, avoiding guessed tombstones. This intentionally
uses full picker resyncs, not an additional native sync database; latency on the
real >30k library remains an acceptance item. Provider and notification instances
serialize snapshot publication and persist generations per account; notifications
carry the actual collection ID, including disabled state. Original seekable reads are limited
to four descriptors, each with a four × 512 KiB range cache, cancellation and
changed-content checks. Preview files have private ownership, size/concurrency
limits and bounded retention. No full original is buffered in RAM.

One Live/Motion asset is one picker item. An intact embedded Samsung Motion Photo
original can be transferred byte-for-byte. An Apple still+MOV pair is not falsely
advertised as a native Android Motion Photo. Ordinary videos remain videos.

See [provider architecture and S23 setup](2026-10-07-cloud-media-s23-pilot.md).

## Shizuku security model

An explicit foreground action requests Shizuku permission and binds a short-lived,
non-daemon UserService. Only wireless shell UID 2000 and the owning app UID are
accepted; root, rish and a computer are not used. Typed AIDL exposes inspection,
admission, recovery and cancellation, not arbitrary command execution or media.

Inspection reads the current Android user, selected verified provider and relevant
DeviceConfig flags. The only privileged mutation is a per-key local override of
`mediaprovider/allowed_cloud_providers`. It preserves all existing entries, Google
Photos and the verified selected provider. Feature/enforcement protections are
not globally disabled. An independently checked raw override/listing and exact
read-back must agree; unrecognized OEM behavior fails closed.

The private recovery journal is persisted **before** the write. Disable opts out
locally even without Shizuku. Recovery restores/clears only the key still exactly
matching our owned write; later external changes are not overwritten. Prior value
whitespace is preserved. A lost acknowledgement, cancellation or revoked permission
keeps recovery pending rather than claiming successful undo. The permission request
can be repeated for an explicit pending recovery.

Normal media reads never use Shizuku. The local override and opt-in are intended
to survive Shizuku stopping/reboot; Samsung's actual persistence and system-provider
selection require the physical test. Wireless Shizuku must be restarted after
reboot only when privileged diagnostics/admission/recovery are needed.

## Library Albums preview

**IMPLEMENTED / TESTED_IN_DEV / NEEDS_PHYSICAL_VALIDATION.** The card previously
read a notifier initially containing `albums: []`, refreshed only by explicit
page actions. It did not subscribe to late album/member/cover sync writes.
`c7f7c44c7d` replaces that card's source with an auto-disposed authenticated Drift
stream, observing album/membership/asset changes with at most four representatives.
Eligible cover → member fallback excludes Trash, Locked/hidden and paired video
companions. Loading, nonempty, empty and retryable errors are separate states;
sync retains a populated mosaic. One image failure leaves the other cached images
visible. No polling, per-album API crawl or originals were introduced.

31 focused tests passed: repository 11, provider 5, widget 7, existing route 1
and Registry customization 7. Focused analyze reported no issues. Tests include
late album, membership and cover rows, empty/cached/slow sync, retry, one thumbnail
failure, account/logout/server-endpoint transitions, old-session events, Trash and
restore. Physical Samsung/iPhone presentation remains unverified.

## Trash stale-response protection

The repository audit reproduced a missing state-version boundary: V1/V2 asset
payloads carry media `fileModifiedAt`, not the revision of Trash, and previously
overwrote `deletedAt` unconditionally. A stale null can therefore reverse known
Trash state. The implementation now guards null upserts and uses the existing
asset endpoint only for conflicting restore transitions, with conditional state
comparison and existing no-ACK/retry behavior on errors. `176008c753` adds
endpoint/owner-scoped retained tombstones in the existing settings table, including
a UUID revision for each successful local Trash operation. It survives reset and
SQLite reopen, suppresses checksum-linked local twins during reset, and guards the
non-stream upload placeholder. Explicit Restore/Delete removes the guard after API
success; logout clears account metadata. Same-second restore→retrash was reproduced
as a failure before the fix, then passed. Ten suites passed **266 tests**; focused
analyze reported no issues. The added settings/store query imports changed only
Drift discovery order; `56dc72218b` updates the v38 serialized snapshot and its
current test helper. Canonical comparison proves all 33 tables/36 indexes and
complete constraints/SQL unchanged. Frozen make-migrations, 55 affected query
tests and three migration tests passed. No schema version bump, new server API or
production migration is involved. See [the state contract](../2026-10-07-trash-stale-state-design.md).

## Memories video root cause and fix boundary

**BLOCKED_EXTERNAL_SOURCE.** Available Gallery code supports ordinary video
embeddings, optional-type Smart Search, mixed photo+video Rule Memories and native
video playback in the Memory Viewer. That proves code support, not actual video
coverage or selection in the external generated Memories the user has viewed.

`SmartInfoService.handleEncodeClip` probes and samples ordinary video frames through
existing local ML. Missing embeddings/previews can exclude a video from Smart Search,
but no production coverage was measured and no reindex/warmup was requested.

All available refs/history/task documents were searched. The external daily
generator location is `/opt/gallery-ai/gallery_ai_memories.py`; the actual renderer
module/container and `StreamingEncoder`/`assemble_streaming` source are not present
in this checkout. Candidate → eligibility → planner → JSON → resolver → renderer
counts for an already completed job are missing. No exclusion stage, ratio, new
selection policy or replacement renderer has been invented.

The exact source/runtime inputs needed are listed in
[the source-boundary report](../2026-10-07-memory-video-vaapi-source-boundary.md).
No external worker, credentials, existing completed Memories or production data
were modified.

## VAAPI existing work and final boundary

**BLOCKED_EXTERNAL_SOURCE / NEEDS_HP_VAAPI_VALIDATION.** `30b2d01b41` records prior
HP `h264_vaapi` work and title handling; it is a task/handoff, not the external
renderer implementation. Its previously reported accelerated encode and CPU
raw-frame/filter bottlenecks are preserved as historical evidence, not a new
benchmark. Gallery's existing VAAPI/QSV media code is a different pipeline.

No speculative `StreamingEncoder`, GPU filter graph, speed claim or UHD 630
HDR/decode capability was substituted for the missing source and runtime evidence.
No `/dev/dri`, governor, FFmpeg/container or HP configuration was changed.

## Tests

Earlier baseline verification (before the new Albums/Trash fixes); final full
shared verification is recorded separately below:

| Check                                                                 | Result                                     |
| --------------------------------------------------------------------- | ------------------------------------------ |
| `flutter analyze --no-pub`                                            | PASS, no issues                            |
| `flutter test --no-pub`                                               | PASS, 4,464 passed, 1 skipped              |
| Four focused Live/Motion suites                                       | PASS, 127 tests                            |
| Focused provider SQL/settings/viewer tests                            | PASS, 55 tests                             |
| Exact production Kotlin policy/MIME/range classes on JVM              | PASS, 24 tests after cancellation-race fix |
| SDK 36 AIDL generation + Java 17 binding compilation                  | PASS                                       |
| Dart format, Prettier, shell syntax, new i18n keys in all ten locales | PASS                                       |
| Focused server Memory/Search/Media/Video Moments suites               | PASS, 578 tests in 4 files                 |
| Existing `smart-info.service.spec.ts`                                 | PASS, 41 tests                             |

Final shared verification after the Android surface fix:

| Check | Result |
| --- | --- |
| Full local `flutter test --no-pub` | PASS, **4,505 passed, 1 skipped** |
| Full local Flutter analyze | PASS, no issues |
| Four focused Live/Motion suites, including actual platform-layer paint regression | PASS, **102 tests** |
| Android release tool after `17fc9ede3b` | PASS, **28 tests** |

The preceding full run was **4,502 passed, 1 failed, 1 skipped**.
The failure was `a memory video becoming non-current while backgrounded never
resumes on foreground`: it expected the initial single `play` call but observed
zero. The fixture had started menu/background transitions before real local-file
source IO was guaranteed to finish. The corrected fixture waits for a bounded,
observable native configuration or source-failure acknowledgement, alternating
real event turns and Flutter fake-frame pumping. Intentionally pending lookup and
muting tests explicitly retain their pending state. Playback counts, lifecycle
behavior, timeout/error guards and the real native integration assertions were
not weakened. The corrected full run above passed; the initial failure is retained
in `flutter-tests-six-streams-final.log`, with the successful run in
`flutter-tests-six-streams-surface-fixed.log` and analyze in
`flutter-analyze-six-streams-surface-fixed.log` under the Cloud validation directory.

The SQL tests execute the provider's actual resource projection against Drift 38,
including >30k pagination, owner/Space/partner isolation, Trash/restore/delete,
hidden companions, stacks, strict local checksums and 5 GiB video metadata.
The streaming tests use real OkHttp/MockWebServer range requests, not a fake reader.

The isolated JVM suite also reproduced the Android graph's OkHttp 5.4.0 +
MockWebServer 4.12.0 mismatch: nine setup failures with
`NoClassDefFoundError: okhttp3/internal/Util`. With both at 5.4.0, the same 23
production-class tests pass. Only the new **test** dependency was aligned;
MapLibre already selects runtime OkHttp 5.4.0 in the existing Android graph.

The full unchanged server suite was also run: **6,578 passed, 2 failed, 1 expected
failure and 12 skipped** (208 files: 205 passed, 2 failed, 1 skipped). Failures are:

- `schema/revert-to-immich.spec.ts`: existing custom migration names are absent
  from the revert test's deletion block.
- `utils/shared-space-album-scope.guard.spec.ts`: its textual guard sees an
  existing import before the visibility gate.

These server files were not changed. The old `check_i18n_keys.py` expects the obsolete
`assets/i18n/en-US.json` path and fails with FileNotFoundError; the current ten-locale
JSON/new-key validation passes. Existing toolchain deprecation warnings were not
addressed by upgrading Gradle/AGP/Kotlin.

## Native CI and artifacts

Native compilation of Kotlin, Java and AIDL succeeded in run `37581653251`,
source `a3eed5f95e68f7824432c5a9cd33cb2c4f0278f3`. Its 23 JUnit tests had 14 passes
and nine MockWebServer setup failures caused by the dependency mismatch above.
The subsequent run `37583385673`, source `329c8b08e7e213e4f53379f90679d96ad6c3815b`,
passed full Android native compilation and all 23 JUnit tests with the aligned
test dependency, and the full Flutter regression stage passed. Its actual native
timeline playback step **failed**; the APK stage was skipped. The test is retained
unchanged. Run `37601475848` adds failure-log check annotations, because the original
full job-log redirect to `productionresultssa7.blob.core.windows.net` is denied by
this cloud environment's destination policy. A targeted environment draft addition
was saved; this does not establish applied access. The diagnostic run compiled/installed the real integration APK, then failed at
its assertion that native playback position advanced. Authentication opened the
synthetic media, but native progress was false. `752d90a174` retains bounded
state/source/load/readiness/completion diagnostics on failure without weakening
that assertion; run `37605054032` is checking the same player. `e64f838d5b` filters
logging to the intended anonymous stage records. That run failed earlier in frozen Drift snapshot verification; its full log
identified the serialization-order issue described above. Native paint regression
was separately reproduced and corrected without weakening the real-player test.
Final emulator progress/completion and APK/artifact results remain gated by the
next actual native run at that point in the history.

That emulator gate subsequently passed in
[run `37606900893`](https://github.com/docice545/gallery/actions/runs/37606900893),
at source `04f2e1ecf6ccb8b460383ee8a3fd37bfafc50748`. Frozen code generation,
native Kotlin/Java/AIDL compilation, all **24 JUnit tests**, clean Flutter analyze
and the shared suite (**4,505 passed, 1 skipped**) passed. The real integration
APK compiled and installed on the API 35 emulator. Its existing authenticated
native HTTP/player path read the synthetic fixture once: **1 authorized request,
0 rejected requests, 8,301 bytes**. Native readiness reported **160×90**; observed
playback position advanced from **213 ms to 1,484 ms** of a **1,500 ms** clip.
The recorded sequence included `selected`, `source:server-pair-playback`,
`platform-view-created`, `native-load-accepted`, `native-ready:160x90`,
`play-request-accepted`, `position-advanced`, `finished:ended` and `lease-revoked`.
The test passed its natural-end, no eight-second timeout and no second-photo
cascade assertions. This validates the synthetic real Android decoder path;
physical S23 codec/composition, production pairing and performance still require
the acceptance steps below. Emulator teardown logged `DELETE_FAILED_INTERNAL_ERROR`
while uninstalling the test package; the disposable emulator was then terminated.

The same run's **release APK build failed** afterward:
`GeneratedPluginRegistrant.java` referenced the absent
`dev.flutter.plugins.integration_test` package. The successful native playback
step is therefore not a successful release APK/artifact result. After an
integration test, Flutter 3.47.2's `--no-pub` release path skips the mode-specific
plugin regeneration and can retain the debug registrant on the release classpath.
The standard pub-enabled release configuration-only preparation was reproduced
locally: it removed that dev-only registration and left `pubspec.lock` unchanged.
`17fc9ede3b` updates CI and the HP release tool to perform frozen dependency
refresh followed by normal pub-enabled release preparation. CI verifies that the
lockfile remains unchanged; the HP tool also compares the tested resolved package
graph. The next Android run is [`37656011448`](https://github.com/docice545/gallery/actions/runs/37656011448),
at source `17fc9ede3b934b76617e3c03f70109ff33d6d38b`; it is still running.
No successful release APK, certificate verification or APK SHA is claimed yet.

Two earlier CI setup failures were diagnosed and corrected without dependency
upgrades: the SDK action's removed `tools` package, then the ignored Flutter Gradle
wrapper missing before the first native unit-test invocation. Neither failure
reached compilation of the new native code.

Run `37580058770` did reach Kotlin compilation and failed on the new notification
call's missing collection-ID argument. This implementation error was corrected
against the actual SDK 36 method signature. Run `37581410545` was superseded/cancelled
when account-scoped atomic collection publication was completed; it is not a pass.

The validation lane has no release signing keys or store upload. A CI debug-signed
APK **cannot update** the existing HP-key-signed installation; do not uninstall
the family app to work around a certificate mismatch. Rebuild the same tested
source on HP with the existing `foto` key for physical S23 acceptance.

## iOS impact

The new provider/admission implementation is Android-only. Shared Flutter logging
uses the existing logger; the new pre-ready paint exception is Android-only.
iOS paired source, sharp face-aware timeline, native
Pigeon/Swift contracts, targets, entitlements, bundle IDs and signing are unchanged.
Shared tests pass. Any unsigned native iOS compile result must be reported separately;
no physical iPhone validation or signing is implied.

## Reproducible release tooling

`5b5a039f1a` adds [the operator runbook](../../docs/RELEASE_RUNBOOK.md), the Android
`preflight/build/postflight` tool and existing unsigned iOS lane dispatch/fetch
verification. The separate SideStore seed script operates on a staged copy,
retains Runner/Share/Widget and Russian `Фото`, keeps ASCII registration-facing
names, and prepares the documented AppGroupId/ShareMedia mapping without paid
credentials. Native identities and normal project configuration are unchanged.

Tool tests: Android 23; iOS-related 82 (20 new); unsigned packager 22 — all PASS.
Ruff lint/format and shell syntax pass. Failure exits, wrong revision/certificate,
missing artifacts, unsafe ZIPs, idempotency and absence of signing-secret output
are covered. Read-only/offline fixture checks ran. The real HP release-key build
is **PREPARED BUT NEEDS HP VALIDATION**; real seed codesign is **PREPARED BUT NEEDS
MACOS AND PHYSICAL IPHONE VALIDATION**. No fake signing key was substituted.

In the latest continuation, the Android release-tool suite passed **28 tests**
after `17fc9ede3b`, including exact fork provenance and preservation of the tested
dependency graph through release preparation. This is local tooling validation;
it does not substitute for an actual HP build with the existing `foto` key.

`ab0d0205c30b313b97bbcf64641bb073de864dd5` fixes the confirmed unsigned-iOS
operator retry defect: a valid existing output is verified against its exact
original successful run and reused, instead of dispatching another run and then
rejecting its differing run ID. Wrong receipts/checksums fail before dispatch.
The runbook distinguishes final checkout HEAD from each actual artifact source
SHA. The latest iOS-related suite passes **86 tests**, and packaging passes
**22 tests**; shell syntax, Python compilation, Ruff and Prettier pass.
Native iOS compilation for this new handoff has not yet run.

The release-fix Git push initially received repeated remote Internal Server Errors.
Read-only/API diagnostics verified exact committed blobs/tree; a REST commit
whose SHA differed was never attached to any ref. A later normal Git push
succeeded at the original `17fc9ede3b` SHA, preserving every parent and commit.
The subsequent `ab0d0205c3` commit was also pushed normally.

**NO SERVER DEPLOYMENT REQUIRED.** Server deployment/rollback and Memories/VAAPI
setup/rollback tools are NOT REQUIRED because those runtimes were not changed.

## Production impact and physical acceptance

No server/API/physical DB schema change, deployment, service restart, original-media write,
Takeout work, Memories warmup, signing-key change or production networking change
was performed. PostgreSQL/Redis/ML/Big-LaMa, Synology, external AI Memories,
auto-stack/Anna exclusion, VPN/AWG/Xray/DNS/nginx/Lampac were untouched.

- **S23 Android 16 / One UI 8.5:** follow the linked Shizuku → Wireless debugging
  → permission → admission → system source selection → server-only photo procedure.
  Also test large video/seek/cancel/offline, MIME, Trash/Locked/companions, account
  switching, Spaces/stacks, >30k library, Google preservation, reboot and exact undo.
  For timeline stillness, export the bounded stage records and actual APK commit.
- **iPhone:** check the retained paired source, mute/one-shot behavior, face-aware
  sharp still and switching/navigation on a physically installed free-signing build.
- **HP:** supply the existing external source and anonymized completed-job evidence
  before changing selection/rendering. Validate the already-deployed VAAPI path on
  selected fixtures without another historical analysis or unrelated service restart.
