# FOTO Build 35: editor copies and synchronization recovery

Base: `f61b05e1637466db9b53368c7ae6a2bbe76498a0`, branch
`integration/foto-build32-checkpoint`. Review branch:
`codex/foto-build35-editor-timeline-fix`. No production service, user database,
NAS original, Android application ID or signing configuration was changed.

## Findings and scope

| Defect                                                            | Reproduction and cause                                                                                                                                                                                                                                                                                                                         | Change                                                                                                                                                                                                                                           |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Incomplete deletion acknowledgement blocks remote sync and backup | The Android log contains the parser/retain/sync stack and subsequent backup failure. A test reproduces the same exception using repeated IDs and the Build 29 contract, which returns one status per input ID. The parser expects unique IDs. The log does not contain the actual request IDs, so their historical values cannot be recovered. | Normalize IDs before 200-ID batching. Keep strict response validation; incomplete, foreign, malformed and duplicate response rows still fail. Failed events do not advance the sync checkpoint.                                                  |
| Ordinary editor copy absent from Photos                           | Save discarded the returned MediaStore identity, joined a potentially older full local sync, and did not verify Drift import. The output bucket defaults to unselected; the normal Photos and backup queries exclude its local files.                                                                                                          | Import exactly the returned PNG identity, verify the actual output path and bucket membership, select only that bucket, update its Drift row/link, and verify the result. Existing reactive timeline queries remain unchanged.                   |
| Retry can lose an already-created copy                            | A metadata/indexing error occurs after native file creation; a retry must not export/save another physical file. A late native response can also arrive after navigation/account switching.                                                                                                                                                    | Retain the created ID and origin importer. Persist a scoped pending import in the existing settings table before retryable work. Reuse that identity for MIME completion/import; no rollback deletion for this editor path.                      |
| Existing hash pass can miss the new copy                          | Hashing snapshots albums/assets before the copy is imported. Joining that pass does not prepare the new upload candidate.                                                                                                                                                                                                                      | Queue and await one coalesced follow-up through the existing hash manager before waking normal backup. Keep cancellation and SQLite recovery barriers.                                                                                           |
| Local-only viewer has Upload but no trash action                  | The viewer connected only the remote DeleteAction, which correctly hides itself without a remote ID.                                                                                                                                                                                                                                           | Connect the existing device cleanup action for local-only assets. Remote/merged actions, ownership, readonly and Locked gates remain intact. No MediaStore implementation change.                                                                |
| Magic Eraser copy uses the source date                            | Both the save service and EXIF writer preferred the source capture date; initial upload also stored a UTC wall-clock date for local grouping.                                                                                                                                                                                                  | Freeze the server save instant and optional device offset for that job. Write new EXIF date/offset/subseconds, upload timestamps and only the newly-created copy's initial localDateTime. Retain uploaded ID before retryable date finalization. |
| Scrubber throws with multiple positions                           | A shared primary controller can temporarily have several ScrollPositions. Its `.position` getter throws. Removing an active drag detector can additionally leave drag state set.                                                                                                                                                               | Use a single usable position, disable ambiguous scrubbing, and end drag bookkeeping when its detector disappears or is cancelled. The floating date label stays disabled.                                                                        |

The screenshot supplied with the supplement shows **Upload** ("Загрузить"). It is
consistent with a local-only asset, but neither its exact asset ID nor ownership
can be established from that screenshot. The viewer defect is independently
reproduced in widget tests; real device deletion is not claimed.

## Editor import safety

- An output album is enabled only after the saved identity, unique generated
  filename, image dimensions, creation time (when supplied), exact
  `DCIM/Noodle Gallery` relative path and native bucket membership are checked.
  A namesake folder alone is insufficient.
- The existing global backup-enabled switch and upload network policy still
  apply. Camera, Screenshots and other album choices are not changed. Enabling
  the editor output bucket also makes its existing eligible files normal backup
  candidates; it does not create a linked server album.
- Import retries never save/render a second PNG. Metadata failure retains the
  new identity; default download rollback behavior remains unchanged.
- Pending records are isolated by endpoint and account. A late save can journal
  its origin scope after account navigation, but cannot import/upload under the
  replacement account. Fresh identity is checked before native MIME mutation.
- Normal Android local sync recovers only these pending editor IDs, including
  no-delta runs. Recovery uses one attempt per item, a bounded fair batch and a
  total two-second budget with cancellation checks. Failed records remain
  diagnosable and retry later. No database schema migration or second worker was
  added. Non-Android saves retain their previous platform synchronization path.
- Successful local import does not wait for the network upload. If the server is
  unavailable, the selected output album and existing backup pipeline retain the
  normal retry path.

## Magic Eraser API and deployment boundary

The optional JSON save body is `{ "timeZoneOffsetMinutes": 180 }`, for example.
The server chooses the save instant; a client cannot choose a historical capture
date. Existing bodyless clients remain supported and use UTC. OpenAPI and the
generated TypeScript/Dart clients were regenerated; the body remains optional.

The existing EXIF parser rejects some offsets, including UTC-12 and nonstandard
minute offsets. These hints receive an explicit HTTP 400 before saving; no global
parser setting is changed and there is no silent timezone substitution. Tested
round trips include UTC, UTC+3, UTC+5:30 and UTC-10, with conflicting source GPS
and timezone, two metadata extractions, and unchanged source bytes/dates.

Production is reported by the owner as Build 29. **The Magic Eraser date change
requires the reviewed backend code as well as the mobile change. Installing only
the APK against the old backend cannot repair its source-date policy.** No backend
deployment was performed. The existing Magic Eraser job/session lifetime remains
process/TTL-bound; this patch does not add cross-restart job persistence.

## Validation record

Application-code checkpoint: `477afbded55bccff6e5a7386fbe4430ea289a182`.
The final report commit adds documentation only.

**NOT RELEASE READY.** The requested fixes are implemented and their targeted
regression suite passes, but the full suites have the failures below. They have
not been disabled or counted as successful checks.

| Check                                                                            | Result                                                                                                                      |
| -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Final focused Flutter regression (15 files)                                      | **PASS: 311 tests**                                                                                                         |
| Full Flutter analyze                                                             | **PASS: no issues**                                                                                                         |
| Full Flutter tests at the application checkpoint                                 | **FAIL: 5,824 passed, 9 failed**                                                                                            |
| Exact-base comparison of eight existing failures                                 | **122 passed, the same 8 failed**, five unchanged test files on `f61b05e…`                                                  |
| Additional thumbnail-cache test                                                  | **Unresolved intermittent FAIL** in the final full run; passed in the first full run and isolated exact-base run            |
| Magic Eraser server/controller/repository tests                                  | **PASS: 74 tests**                                                                                                          |
| Real EXIF plus disposable PostgreSQL and repeated metadata extraction            | **PASS: 4 tests**                                                                                                           |
| Full backend unit tests                                                          | **FAIL: 7,017 passed, 1 failed, 1 expected failure, 12 skipped**; 219 files passed, 1 failed, 1 skipped                     |
| Failing backend contract on exact base                                           | **FAIL: 6 passed, 1 failed**, same pinned-schema digest mismatch                                                            |
| Final optional save-body contract tests                                          | **7 passed, 1 existing schema-digest failure**; the additive body is explicitly checked, all other operations remain pinned |
| OpenAPI generation, Dart client generation, TypeScript SDK build                 | **PASS**                                                                                                                    |
| Server build and TypeScript check                                                | **PASS**                                                                                                                    |
| Scoped server ESLint/Prettier; changed locales, SDK/spec formatting; Dart format | **PASS**                                                                                                                    |
| `git diff --check`                                                               | **PASS**                                                                                                                    |
| Flutter debug bundle compilation from a separate exact-source worktree           | **PASS**                                                                                                                    |
| Android release assembly targeting ARM64                                         | **PASS: unsigned compile artifact**, package/version 5.7.3+35 verified; see limitations below                               |
| Signing, update over Build 34, Samsung/HP/Synology tests                         | **NOT TESTED**                                                                                                              |

The eight reproduced baseline Flutter failures are two mosaic expectations,
three remote Live Photo expectations, and three legacy deleteLocal visibility
expectations. No mosaic or Live Photo source/test was changed in this patch.
The ninth failure is
`timeline_thumbnail_quality_widget_test.dart: completed still cache entry and
provider survive motion start, face arrival and one-shot completion`; an isolated
baseline PASS does not prove that intermittent failure is harmless.

The remaining server failure is
`client-contracts.spec.ts: preserves every existing schema except additive sync
enum extensions`. Its normalized digest is
`7fe64572752448c06cb4906a3b2e69ad55330dfdaf6fed750b642cd9ab770a50`
on **both** `f61b05e…` and this change, whereas the fixture expects a different
digest. Pinned historical differences include `PermanentDeletionDto` and
`PermanentDeletionResultDto`; these schemas are unchanged by Build 35. The old
fixture was not rewritten. The newly optional Magic Eraser body is validated
before normalizing only that additive extension for the existing operation
digest. Actual bodyless HTTP compatibility also has a passing controller test.

The first broad Node test attempt exhausted its default 2 GB heap. The recorded
final run used `NODE_OPTIONS=--max-old-space-size=4096`; this changes test-process
capacity, not assertions or application dependencies. Skipped/expected-failure
tests are listed separately from PASS.

### Android build result

The code checkpoint compiled as an unsigned release APK in a separate worktree:

- Source: `477afbded55bccff6e5a7386fbe4430ea289a182`.
- Artifact: `/workspace/gallery-build35-build-check/mobile/build/app/outputs/flutter-apk/app-release.apk`.
- Package: `de.opennoodle.gallery`; versionName `5.7.3`, **versionCode 35**;
  minSdk 26, targetSdk 36, non-debuggable.
- SHA-256: `cd89de4ecb5efbcd26e6bd359cb07f3d2544e95766688dbf55eae90514aa6672`.
- `libapp.so`, `libflutter.so` and `libsqlite3.so` are ARM64. The unsplit APK
  also contains some other-ABI plugin libraries; it is not proof of working
  non-ARM64 variants.
- Unsigned status was checked using apksigner and ZIP/signature-block inspection.
  No production/debug signing key was present or created. This artifact cannot
  establish an update over Build 34 and is not a release for installation.

An additional `--split-per-abi` packaging check produced a valid ARM64-only APK
but **versionCode 2035**, because this pinned Flutter toolchain adds an ABI
version-code offset. That artifact is not Build 35's update candidate and must
not be substituted for the code-35 artifact. HP commands below intentionally use
the unsplit build. No Gradle version-code override or signing change was made.

Fresh-worktree build preparation needed all Pigeon native outputs and the normal
release Pub/platform-tooling regeneration. Cloud Maven access used the session
proxy and a temporary public CA trust store with TLS/hostname validation enabled.
No SDK/dependency version, global network setting or tracked source was changed
to obtain the successful build.

Source inspection also confirms no `server/` or OpenAPI difference between the
reported production Build 29 source `170f972f8…` and required base `f61b05e…`.
This is a Git comparison, not a verification of the running production container.

### Reproduce the focused mobile checks

From `mobile/`, after code generation:

```bash
flutter test --concurrency 2 \
  test/repositories/{permanent_deletion_api_repository,file_media_repository,magic_eraser_repository}_test.dart \
  test/domain/services/{sync_stream_service,local_sync_service,edited_copy_service,instant_trash_acceptance_service}_test.dart \
  test/domain/utils/background_sync_test.dart \
  test/pages/edit/{editor_save_retry,editor_copy_import}_test.dart \
  test/presentation/widgets/asset_viewer/viewer_local_deletion_test.dart \
  test/presentation/widgets/timeline/{scrubber_positions,scrubber_segments,timeline_scrubber_offset}_test.dart \
  test/infrastructure/repositories/instant_trash_acceptance_test.dart
```

### Logical commits

| Commit      | Scope                                                                 |
| ----------- | --------------------------------------------------------------------- |
| `837f59616` | Normalize durable deletion receipt request IDs                        |
| `7493fe0ab` | Connect existing local viewer delete action                           |
| `d4f920864` | Guard ambiguous Scrubber positions                                    |
| `aeaa51d2a` | Retain native-created copy identity on metadata failure               |
| `06710bf39` | Release detached/cancelled Scrubber drag                              |
| `6102dd5ac` | Coalesced post-import hashing, cancellation and SQLite barrier        |
| `524fe7891` | Exact copy import, scoped recovery, own-album backup and editor retry |
| `4465e2417` | Actual-save date/offset/EXIF and optional API/client generation       |
| `5aa0fedf5` | Incomplete native title/date/path handling                            |
| `477afbded` | Pin the optional API hint without changing legacy fixture digests     |

Results and final source SHA are recorded in the PR. Reproducers were run before
the corresponding corrections, including repeated deletion IDs, shared scrubber
positions, and a real TestGesture whose detector disappears while dragging.
Tests use synthetic identities/media and disposable databases, never production.

The new regression coverage includes strict receipt failure/retry/checkpoints;
reactive Drift timeline import and normal backup candidates; retry without a
second file; delayed indexing; metadata completion; account/server isolation;
restart recovery and cancellation; non-Android fallback; local viewer permission
gates; current-save EXIF dates; and scrubber detach/cancel behavior.

Hardware checks remain **NOT TESTED**: actual Samsung MediaStore permissions and
system consent, Samsung rendering/gestures, real network transitions, production
backup completion, HP/NFS behavior, signed update over installed Build 34, and
physical iOS behavior. Unit/widget tests do not establish these results.

## Safe HP review and later Build 35 assembly

These are owner-run instructions after PR review. They do not merge or deploy.
Use the full reviewed source SHA from the PR; do not substitute a moving HEAD.
Keep any dirty checkout and `.pre-*` backups in place.

```bash
cd /home/doctoriceadm/gallery-build29-integration
git status --short
git fetch origin
git fetch origin refs/heads/codex/foto-build35-editor-timeline-fix:refs/remotes/origin/codex/foto-build35-editor-timeline-fix
foto35_sha='<full reviewed PR head SHA>'
test "$(git rev-parse origin/codex/foto-build35-editor-timeline-fix)" = "$foto35_sha"
git merge-base --is-ancestor f61b05e1637466db9b53368c7ae6a2bbe76498a0 "$foto35_sha"
git worktree add --detach /home/doctoriceadm/foto-build35-review "$foto35_sha"
cd /home/doctoriceadm/foto-build35-review
git diff --check f61b05e1637466db9b53368c7ae6a2bbe76498a0..HEAD
```

Use the repository-pinned toolchain and existing HP caches. Generate the Dart
client using `mise //:open-api-dart`, then from `mobile/`:

```bash
flutter pub get --enforce-lockfile
mise //mobile:codegen
git diff --exit-code
flutter analyze
flutter test --concurrency 2
```

The existing codegen task generates Pigeon Kotlin/Swift/Dart bridges, Drift test
fixtures and localization, including `easy_localization:generate` and
`bin/generate_keys.dart`. Generating only Dart build_runner output is insufficient
for a fresh Android worktree. Stop if codegen unexpectedly changes tracked source.

Only after those checks and a release decision, configure the fresh worktree to
use the **existing HP production key** through the existing private signing
configuration (absolute key path). Keep keys/passwords on HP; do not create or
copy a new key, commit private files, or paste passwords into command history.
If that key is unavailable, stop: an unsigned cloud artifact is not an update.

```bash
env -u PR_NUMBER flutter build apk --release --target-platform android-arm64 \
  --build-name 5.7.3 --build-number 35
apk_path=build/app/outputs/flutter-apk/app-release.apk
apksigner verify --verbose --print-certs "$apk_path"
aapt2 dump badging "$apk_path"
unzip -l "$apk_path" 'lib/arm64-v8a/libsqlite3.so'
sha256sum "$apk_path"
```

Require package `de.opennoodle.gallery`, versionCode 35, and certificate SHA-256
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
Do not uninstall/clear Build 34 or install a lower-version APK. Perform the
update-preservation test manually on Samsung only after signature verification.

Keep the build command's normal Pub/platform-tooling step. A `--no-pub` build
after generating a debug bundle can retain a debug GeneratedPluginRegistrant
while release Gradle correctly excludes the integration_test development plugin.
The standard build regenerates the release registrant. Do not manually remove a
plugin or disable tests to work around stale generated tooling.

For the date fix, build a new backend image from the same reviewed source using
the existing `server/Dockerfile` and repository branding/build process. First test
it in isolated staging with synthetic assets and the unchanged Big LaMa service.
No migration is introduced. Keep the production Build 29 image/configuration
available. Changing any running container requires a separate owner decision.

## Physical acceptance scenarios

1. With Noodle Gallery unselected and Camera/Screenshots unchanged, crop/draw and
   save a copy. Verify a new local identity appears in Photos immediately, the
   original is unchanged, and normal enabled backup eventually produces one
   merged tile. Repeat while another local sync/hash pass is running.
2. Repeat offline, with limited photo permissions, after a transient metadata
   error, and after closing/restarting the app. Retry imports the same file.
   Reconnect and verify one upload, not duplicate files.
3. Switch account/server while native save is pending. The replacement account
   must not receive the old copy automatically; returning to its origin allows
   scoped recovery.
4. On the reviewed staging backend save a Magic Eraser copy near local midnight,
   with an old source in a different timezone. Check the new day/time before and
   after metadata extraction and resync; original timestamps remain unchanged.
5. Verify local-only viewer trash uses Android system consent; cancel consent and
   verify no false deletion. Verify foreign, readonly and Locked restrictions.
6. Re-run remote sync after the receipt failure. Confirm it progresses and backup
   starts; invalid/incomplete receipts must still stop checkpoint advancement.
7. Rapidly navigate/scroll timeline routes while dragging the scrubber. Check no
   exception or stuck scrolling state and no floating date label.

This cloud result is ready for code review and the documented device/staging
checks, not a claim of production or physical-device acceptance.

## Changed files

```text
i18n/de.json
i18n/en.json
i18n/es.json
i18n/fr.json
i18n/it.json
i18n/nl.json
i18n/pl.json
i18n/ru.json
i18n/zh_Hans.json
i18n/zh_Hant.json
mobile/lib/domain/services/edited_copy.service.dart
mobile/lib/domain/services/local_sync.service.dart
mobile/lib/domain/utils/background_sync.dart
mobile/lib/presentation/pages/edit/edit.page.dart
mobile/lib/presentation/widgets/asset_viewer/bottom_bar.widget.dart
mobile/lib/presentation/widgets/timeline/scrubber.widget.dart
mobile/lib/providers/infrastructure/sync.provider.dart
mobile/lib/repositories/asset_api.repository.dart
mobile/lib/repositories/file_media.repository.dart
mobile/lib/repositories/magic_eraser.repository.dart
mobile/test/domain/services/edited_copy_service_test.dart
mobile/test/domain/services/local_sync_service_test.dart
mobile/test/domain/services/sync_stream_service_test.dart
mobile/test/domain/utils/background_sync_test.dart
mobile/test/pages/edit/editor_copy_import_test.dart
mobile/test/pages/edit/editor_save_retry_test.dart
mobile/test/presentation/widgets/asset_viewer/viewer_local_deletion_test.dart
mobile/test/presentation/widgets/timeline/scrubber_positions_test.dart
mobile/test/repositories/file_media_repository_test.dart
mobile/test/repositories/magic_eraser_repository_test.dart
mobile/test/repositories/permanent_deletion_api_repository_test.dart
open-api/immich-openapi-specs.json
packages/sdk/src/fetch-client.ts
server/src/controllers/magic-eraser.controller.spec.ts
server/src/controllers/magic-eraser.controller.ts
server/src/dtos/magic-eraser.dto.ts
server/src/repositories/magic-eraser.repository.spec.ts
server/src/repositories/magic-eraser.repository.ts
server/src/services/magic-eraser.service.spec.ts
server/src/services/magic-eraser.service.ts
server/src/utils/client-contracts.spec.ts
server/test/medium/specs/services/magic-eraser-copy-date.spec.ts
specs/testing/2026-11-02-foto-build35-editor-sync.md
```
