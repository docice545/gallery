# FOTO Build 18 Android release and device validation

The required baseline is `e5883358c48a76a82fe7db29b5cd5ac0b1fc76e2`.
The release identity remains `de.opennoodle.gallery`, version `5.7.3`, versionCode
`18`. Use Flutter `3.47.2`, its bundled Dart SDK, Java `21.0.2`, the checked-in
Gradle wrapper, and the Android SDK/NDK selected by that Flutter release. Preserve
`pubspec.lock`; generate OpenAPI and Dart sources using `mobile/mise.toml` before
testing or building. Do not reuse generated sources from a different revision.

## Reproducible release compilation

On the isolated checkout, after the documented dependency/code-generation tasks:

```sh
cd mobile
flutter analyze --no-pub
flutter test --no-pub test/domain/services/local_sync_service_test.dart \
  test/domain/services/sync_stream_service_test.dart \
  test/domain/services/local_trash_sync_service_test.dart \
  test/infrastructure/repositories/trash_local_sync_test.dart \
  test/infrastructure/repositories/pending_local_trash_repository_test.dart \
  test/repositories/asset_media_trash_repository_test.dart
flutter test --no-pub test/domain/utils/background_sync_test.dart \
  test/domain/services/background_work_lifecycle_test.dart \
  test/unit/utils/isolate_worker_test.dart \
  test/drift/main/migration_test.dart
flutter test --no-pub test/infrastructure/loaders/remote_image_request_test.dart \
  test/presentation/widgets/images/remote_image_provider_http_test.dart \
  test/unit/utils/image_url_builder_test.dart test/utils/image_url_builder_test.dart
cd android
./gradlew :app:testDebugUnitTest --tests '*SyncTrashPolicyTest' --tests '*RemoteImageHttpErrorTest'
cd ..
flutter build apk --release --pub --build-name=5.7.3 --build-number=18
```

The existing Gradle release configuration produces an unsigned release when the
existing production keystore is unavailable. Do not create a replacement key,
select a debug signing configuration, change the package ID or replace the
installed production APK. Successful release compilation alone does not qualify
an APK for rollout.

Use `--pub` for the final release command. In this pinned Flutter version,
`--no-pub` also skips regeneration of platform plugin registrants. A registrant
left by development tooling can reference `integration_test`, which is correctly
excluded from the release dependency graph. Let the SDK regenerate its release
registrant; do not edit generated files or remove the testing dependency.

## Signing with the existing HP identity

Perform signing locally on HP using the existing production key and its normal
secret handling. No key, password or secret file should be uploaded to a cloud
agent. The following commands operate on new artifact paths only; use the
already-configured Android Build Tools and existing keystore/alias:

```sh
zipalign -p -f 4 build18-unsigned.apk build18-aligned.apk
apksigner sign --ks "$FOTO_EXISTING_KEYSTORE" \
  --ks-key-alias "$FOTO_EXISTING_KEY_ALIAS" \
  --out build18-signed.apk build18-aligned.apk
apksigner verify --verbose --print-certs build18-signed.apk
apksigner verify --verbose --print-certs build17-production.apk
aapt dump badging build18-signed.apk
sha256sum build18-signed.apk
```

Let `apksigner` prompt locally for passwords; do not pass them as command-line
arguments or paste them into chat. Require an identical signing certificate
SHA-256 digest to Build 17, the unchanged package ID and a versionCode greater
than Build 17 before attempting an update. Preserve the existing production APK
as a read-only reference. This document does not authorize changing HP settings
or deploying server components.

## Physical Samsung acceptance

Use a separate test device/profile and synthetic photos, without production
accounts or originals. Install Build 18 over a Build 17 installation signed with
the same existing identity. Verify that albums, settings, login state and local
database survive the update. Do not uninstall to bypass update failures.

With deletion synchronization enabled, test new-photo discovery and backup
during stale-ID, partial-trash and denied-trash conditions. Check full and
limited media access, MANAGE_MEDIA revocation/regrant, process termination with
pending work, foreground/background transitions, activity recreation, repeated
server events and device restart. Confirm that only verified results disappear
from the pending intents and retries remain delayed after failures.

Verify that server Trash and permanent deletion preserve their existing local
trash-only semantics, repeated processing does not refresh OS trash expiry or
duplicate photos, and server Restore never recreates a device file. Restore and
permanent deletion tests must use synthetic test media only. Preserve logs with
per-ID diagnostic codes; the generic historical PhotoManager exception is not
enough to attribute a failure to Samsung or Android 16.
