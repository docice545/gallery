# «Фото»: iOS implementation and acceptance

Specification: [completed readiness audit](../2026-10-05-ios-readiness-design.md).
Starting commit: `a1ab0826ab266ea6ad09f19ab9288805b606eab2`. Existing iOS WIP was
preserved; the subsequent shared Samsung autoplay correction is included.
This document records implementation and validation boundaries, not a new audit.

## Background lifecycle

`BackgroundWorkLifecycle` owns initialization and all sync/hash/upload-queue
futures. A deadline requests cancellation instead of detaching an active future
with `Future.timeout`. Shutdown stops accepting work, signals cancellation,
awaits native sync/hash cancellation, awaits active phases, detaches and drains
upload callbacks, drains log writes, then closes services/DB. Bootstrap failure
closes partially initialized resources too.

`onIosUpload` returns a real Boolean result after draining. Swift counts both
upload and cancellation Pigeon replies, waits for Dart initialization before
sending expiration cancellation, and completes/destroys the engine once after
drain. Failure, expiry and cancellation do not report success. A broken channel
does not prove that work has drained. The former forced two-second destruction
is removed. Plugin detach blocks late replies.

Native background URLSession transfers retain their existing architecture:
queue completion is not a promise that every network upload has finished.
Callbacks into this Dart engine are stopped and drained; ongoing system-owned
transfers can resume under the existing upload mechanism. iOS may terminate a
process when its execution budget expires; software cannot guarantee otherwise.
Physical expiration/resume tests remain mandatory.

## Cache ownership

iOS `StorageRepository.clearCache` clears only
`getTemporaryDirectory()/gallery_disposable_cache`. It never purges systemTemp,
Library/Caches, App Groups, SQLite/log files, PhotoManager's exported originals,
device-downloads or outgoing_share as a whole. PhotoManager's broad cache purge
is skipped on iOS because it lacks active-reader ownership information. Android
retains its previous PhotoManager behavior.

The disposable helper supports cross-engine `active-*` directory leases. Pair
members share a lease; only a post-drain atomic rename makes them disposable.
Active leases are not expired by age. Root/child symlinks are not followed.
This new directory is an explicit boundary for disposable data; existing export
producers have not been moved into it. Consequently this action deliberately
does not reclaim PhotoManager original exports still governed by plugin lifecycle.

Outgoing share originals/pairs retain the existing seven-day receiver contract.
An incoming App Group handoff is published atomically with `.complete` and a
small versioned `.live-photo.json` manifest. Main-app uploads mark `.active`;
successful handoffs become `.consumed`. Cleanup removes a whole consumed,
inactive directory only after seven days, never one half of a pair.

## Live Photo transfer and save

Swift-only Pigeon contracts are in `live_photo_api.dart` and
`live_photo_save_api.dart`; no Android stubs or platform parity claims are added.
Local outgoing transfer exports immutable `.photo` and `.pairedVideo` PhotoKit
resources. Server-only transfer downloads original still and linked motion via
existing authenticated streaming/file downloads, preserving bytes and pairing
metadata. No original is rewritten or automatically added to Photos for Share.

The pair validator checks Apple's still identifier and matching QuickTime content
identifier, then asks PhotoKit to construct a valid `PHLivePhoto`. Cancellation
waits for PhotoKit's terminal callback before either resource can be released;
request-ID registration races and degraded cancellation/error callbacks are
handled explicitly. Every outgoing Share has its own operation identity so a
late cancelled callback cannot present or complete a later Share. Outgoing native
Share uses the public NSSecureCoding NSItemProvider contract and
`UIActivityItemsConfiguration`; compatible recipients can request `PHLivePhoto`.
Invalid pair transfer fails instead of silently sharing only the image. The Share
choice explicitly offers motion preservation versus original image-only sharing;
preview sharing is also an intentional still-only operation. Public contract use
does **not** prove each receiving app preserves motion: test on a physical iPhone.

Incoming Share Extension reads a native Live Photo, exports its actual PhotoKit
paired resources into the existing App Group, and sends one logical attachment.
Upload uses the existing `livePhotoVideoId` API: hidden motion first, then still
linked to it. Rollback is restricted to a motion resource explicitly reported as
newly created; duplicates/unknown creation status are never deleted. No server
API, database schema, pair model or visible duplicate-asset format is introduced.
Motion upload cancellation/failure preserves the handoff for retry. The app
rejects missing/malformed pair manifests and revalidates the owned pair immediately
before upload; a vanished resource never silently becomes a still-only import.
Failure to acquire the handoff lease also fails before upload.

`saveLivePhoto` results:

| Outcome     | Meaning                                                                     |
| ----------- | --------------------------------------------------------------------------- |
| `livePhoto` | Validated pair saved atomically by PhotoKit with motion                     |
| `imageOnly` | Explicitly permitted still fallback saved; UI says motion was not preserved |
| `failed`    | No successful result can be claimed; stable non-sensitive reason            |
| `cancelled` | Cancelled before successful commit                                          |

Cancellation cannot undo a submitted PhotoKit transaction. A transaction that
finishes successfully during cancellation reports its actual saved outcome.
Success without a usable placeholder is reported as an indeterminate committed
result and never retried automatically or converted into a second still import.
Save requests explicit PhotoKit `.addOnly` authorization; denied/restricted
permission fails before pair validation. Cancellation while permission is pending
finishes before any media reader starts; stale permission replies are ignored.
Add-only saving uses the creation placeholder without querying the library.
The caller retains both temp resources through the awaited native save/cancel
result and cleans them for every outcome. Originals remain unchanged. Samsung
embedded Motion Photo bytes are not falsely advertised as an Apple pair; users
can choose the explicit still path if Apple's representation is unavailable.

## Targets, build and signing

See [build-only validation](2026-10-05-ios-build-only-validation.md) for Runner15,
Share16, Widget17, full pinned codegen, unsigned archive and required artifacts.
The existing GitHub workflow is reused; no duplicate workflow is introduced.
Unsigned compilation is separate from signed export and distribution.

The repository's actual signing mechanism is Fastlane `configure_code_signing`
using `update_code_signing_settings` for all three targets, followed by `sigh`
and `build_app`. There is no separate `set-code-signing-settings` implementation
to invent. Existing signed release lanes use App Store Connect/distribution
credentials and are **not** a free Personal Team solution.

Existing release secret names/types, without values: `APP_STORE_CONNECT_API_KEY_ID`,
`APP_STORE_CONNECT_API_KEY_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY` (base64 p8),
`IOS_CERTIFICATE_P12` (base64 certificate + private key),
`IOS_CERTIFICATE_PASSWORD`, and `FASTLANE_TEAM_ID`. The current code-sign identity
is an upstream publisher identity; a later approved signing stage must use the
actual owner's identity/profiles without committing secrets or silently changing
bundle/App Group IDs. Do not invoke a nonempty release version merely to obtain
an installable test artifact: that lane uploads to TestFlight.

For free distribution the existing
[SideStore/LocalDevVPN pilot design](../2026-10-05-ios-free-distribution-design.md)
remains authoritative. It is not yet an approved production system. Personal
Team identity, AppGroupId/profile consistency, entitlements, refresh reliability
and physically verified current SideStore release are separate gates. No app
dependency on SideStore, Anisette deployment or new signing architecture is added.
Next stage: validate unsigned native compilation, approve the existing distribution
pilot, configure owner signing outside Git, then produce and physically install
the signed IPA using that approved signer. Ubuntu cannot perform the Xcode build.

## Physical acceptance checklist

Record device/iOS/Xcode/build SHA, rights, network, observed outcomes and logs
without tokens, private paths or pairing identifiers. Test supported OS floors
where devices are available; do not infer lower-OS installability from plist values.

- PhotoKit: denied, limited, full and add-only; permission revoked during work;
  local and iCloud-only media; no unnecessary library reads under add-only.
- Live Photos: PhotoKit import, original still/motion identity, local/iCloud-only
  playback, incoming Share Extension cold/warm launch, outgoing to Apple Photos
  and a compatible receiving app, explicit still-only sharing, mixed multi-share,
  Save to Photos valid/invalid pair, PhotoKit failure, fallback failure, cancellation
  before and during commit, no duplicate visible assets, both-temp cleanup.
- Formats/geometry: HEIC/JPEG + MOV/HEVC, portrait/landscape, preferredTransform
  orientation, HDR, face crop/face union/contain, incoming original metadata.
  The pinned native player reports `naturalSize`; transformed iOS video geometry
  needs physical confirmation. Do not assert pixel registration between different
  still/motion camera fields of view from widget tests alone.
- Background: successful sync/hash/queue, real failure, lock/background, expiration
  during initialization/sync/hash/upload scheduling, explicit cancellation, lost
  network, retries/resume, force-quit/relaunch and reboot. Confirm exactly one native
  completion, false on failure/expiry, and no DB/plugin callback after teardown.
- Cache: clear while uploading/downloading/importing/exporting/sharing, iCloud export,
  active Live Photo pair and Share Extension handoff; other temporary files survive;
  retained files survive receiver reads and expire only under their lifecycle.
- Shared UI: dense timeline and sharp still before/after muted one-shot motion;
  80% visibility/350ms/no-loop/no-cascade/scroll cancellation; Memories/AI mixed
  photo-video and zoom, manual stacks/badges, Trash grouping, Magic Eraser save-copy,
  server-only Share/Download, auth/session and foreground/background upload queue.
- Native/release: Runner + both extensions compile; correct App Groups, entitlements,
  all three profiles; signed install/update over prior build; session/local data
  preserved; iOS15 Runner without Share/Widget, iOS16 Share without Widget, iOS17+
  both extensions. Test app-group cookie handoff and background URLSession resume.

## Safety

No production deployment/server build, migrations, PostgreSQL/Redis/ML/Big-LaMa,
Synology originals, VPN/AWG/Xray/DNS/routing, AI Memories or auto-stack worker was
changed. Android signing configuration/keys are untouched. Anna's already completed
Takeout restore is not repeated; the ambiguous member remains unselected and her
automatic-stack exclusion remains intact. HP-local Takeout edits/backups were not
present in this Cloud checkout and are not claimed as copied or committed here.

## Repository validation

The shared Android correction was committed separately as
`7b39a7f73b3de28ae80bddd5e51be94c70c11f6d` and pushed before the iOS commits.

- Android/shared timeline targeted suite: **478 passed**; the helper/player subset
  of **83 passed** is included in that count. Dart analyze: no issues.
- Broad shared mobile regression run: **2453 passed**, including timeline,
  face framing, Memories, stacks, Trash, Magic Eraser, auth, Share/Download and
  upload queue. This is the selected relevant suite, not every mobile test file.
- Background lifecycle/callback/hash tests: **130 passed**.
- Cache ownership/lifecycle tests: **12 passed**.
- Final Share/export/import/upload tests after fail-closed hardening: **79 passed**.
- Final save outcomes/UI/native source guards after cancellation and add-only
  hardening: **49 passed**. PhotoKit outcomes are mocked on Linux; source guards
  are explicitly not execution of Apple frameworks.
- macOS build orchestration/configuration tests: **23 passed** using stub commands
  and fixture archive binaries. They do not prove native compilation.
- Final `flutter analyze --no-pub`: **No issues found**. Scoped `dart format`
  check: **47 files, 0 changes**. Localization/docs/workflow Prettier check passed;
  scoped diff whitespace check passed with the existing CRLF provider preserved.
- Suites overlap; their counts must not be summed as unique tests.
- Pigeon: all 11 definitions generated with the locked 27.3.0 package; generated
  Dart/Swift/Kotlin outputs remain ignored according to existing repository policy.
- All three target plists and entitlements parse; the four new localization keys
  are nonempty in all ten required locales. No new application/server API or DB
  migration is needed.

Native Swift/Xcode, CocoaPods and signed-device behavior require the macOS workflow
and physical checklist above. Android SDK and the owner's `foto` release keystore
are absent in this Cloud checkout. No substitute signing key or debug-signed
release APK was produced; there is no APK checksum to claim. HP build/signature
commands are in the separate Android regression report.

## Changed-file inventory

The following inventory includes the iOS implementation and build-only lane;
Android/shared correction files are listed in its separate regression report.

- `.github/workflows/build-mobile.yml`
- `.github/workflows/gallery-build-mobile.yml`
- `i18n/de.json`
- `i18n/en.json`
- `i18n/es.json`
- `i18n/fr.json`
- `i18n/it.json`
- `i18n/nl.json`
- `i18n/pl.json`
- `i18n/ru.json`
- `i18n/zh_Hans.json`
- `i18n/zh_Hant.json`
- `mobile/android/app/src/main/kotlin/app/alextran/immich/sync/MessagesImplBase.kt`
- `mobile/ios/Flutter/AppFrameworkInfo.plist`
- `mobile/ios/Gemfile`
- `mobile/ios/Podfile`
- `mobile/ios/Podfile.lock`
- `mobile/ios/Runner.xcodeproj/project.pbxproj`
- `mobile/ios/Runner/AppDelegate.swift`
- `mobile/ios/Runner/Background/BackgroundWorker.swift`
- `mobile/ios/Runner/Background/BackgroundWorkerApiImpl.swift`
- `mobile/ios/Runner/Core/ImmichPlugin.swift`
- `mobile/ios/Runner/LivePhotos/LivePhotoApiImpl.swift`
- `mobile/ios/Runner/Sync/AppleLivePhotoPairValidator.swift`
- `mobile/ios/Runner/Sync/LivePhotoSaveApiImpl.swift`
- `mobile/ios/Runner/Sync/MessagesImpl.swift`
- `mobile/ios/ShareExtension/Info.plist`
- `mobile/ios/ShareExtension/ShareViewController.swift`
- `mobile/ios/ci_scripts/ci_post_clone.sh`
- `mobile/ios/fastlane/Fastfile`
- `mobile/lib/data/data_controller.dart`
- `mobile/lib/domain/services/background_work_lifecycle.dart`
- `mobile/lib/domain/services/background_worker.service.dart`
- `mobile/lib/domain/services/hash.service.dart`
- `mobile/lib/domain/services/local_sync.service.dart`
- `mobile/lib/domain/services/log.service.dart`
- `mobile/lib/domain/services/sync_stream.service.dart`
- `mobile/lib/infrastructure/repositories/gallery_temporary_cache.dart`
- `mobile/lib/infrastructure/repositories/storage.repository.dart`
- `mobile/lib/models/download/download_state.model.dart`
- `mobile/lib/models/upload/share_intent_attachment.model.dart`
- `mobile/lib/pages/common/download_panel.dart`
- `mobile/lib/presentation/actions/share.action.dart`
- `mobile/lib/presentation/pages/download_info.page.dart`
- `mobile/lib/providers/asset_viewer/download.provider.dart`
- `mobile/lib/providers/asset_viewer/share_intent_upload.provider.dart`
- `mobile/lib/providers/backup/backup.provider.dart`
- `mobile/lib/repositories/asset_media.repository.dart`
- `mobile/lib/repositories/file_media.repository.dart`
- `mobile/lib/repositories/share_handler.repository.dart`
- `mobile/lib/repositories/upload.repository.dart`
- `mobile/lib/services/background_upload.service.dart`
- `mobile/lib/services/download.service.dart`
- `mobile/lib/services/foreground_upload.service.dart`
- `mobile/lib/utils/bootstrap.dart`
- `mobile/lib/utils/live_photo_import.dart`
- `mobile/pigeon/background_worker_api.dart`
- `mobile/pigeon/live_photo_api.dart`
- `mobile/pigeon/live_photo_save_api.dart`
- `mobile/pigeon/native_sync_api.dart`
- `mobile/scripts/ios_build_only.sh`
- `mobile/scripts/tests/test_ios_build_only.py`
- `mobile/scripts/verify_ios_archive.py`
- `mobile/test/domain/services/background_work_lifecycle_test.dart`
- `mobile/test/domain/services/log_service_test.dart`
- `mobile/test/infrastructure/repositories/storage_cache_test.dart`
- `mobile/test/platform/background_worker_native_files_test.dart`
- `mobile/test/platform/live_photo_save_native_files_test.dart`
- `mobile/test/providers/asset_viewer/download_provider_test.dart`
- `mobile/test/repositories/asset_media_repository_test.dart`
- `mobile/test/repositories/file_media_repository_test.dart`
- `mobile/test/repositories/share_handler_repository_test.dart`
- `mobile/test/services/background_upload_lifecycle_test.dart`
- `mobile/test/services/download_service_test.dart`
- `mobile/test/services/foreground_upload.service_test.dart`
- `mobile/test/unit/mocks.dart`
- `mobile/test/unit/presentation/actions/share_action_test.dart`
- `mobile/test/unit/services/hash_service_test.dart`
- `mobile/test/utils/live_photo_import_test.dart`
- `mobile/test/widgets/download_live_photo_status_test.dart`
- `specs/testing/2026-10-05-ios-build-only-validation.md`
- `specs/testing/2026-10-05-ios-implementation-validation.md`
- `specs/testing/2026-10-05-ios-live-photo-transfer-validation.md`
