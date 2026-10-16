# Codex local Android build — 2026-10-16

This record describes the free, local Android APK build performed on the HP Ubuntu 24.04
environment. It does not use GitHub Actions, production services, VPN/NAS data, or real media.

## Reproduction

From `mobile/`, with the repository's existing SDK checkout and caches:

```bash
flutter pub get
flutter build apk --debug --no-pub
```

The verified toolchain was Flutter 3.47.2 / Dart 3.13.2, Gradle 8.14, Android SDK 36.0.0,
NDK 28.2.13676358, and OpenJDK 17. The project uses the checked-in `mobile/android/gradlew`
wrapper and the existing `GRADLE_USER_HOME` cache on SSD.

## Dependency diagnosis

DNS resolved `dl.google.com`, Maven Central, Gradle Plugin Portal, and `services.gradle.org`.
HTTPS HEAD requests to all four repositories succeeded. No HTTP or HTTPS proxy variables were
set. The Android SDK, Gradle distribution, and most Maven artifacts were already cached.

The apparent Gradle hang was the first uncached build doing dependency downloads and expensive
Android/Kotlin transforms. An offline attempt also exposed a separate limitation: offline mode
fails when a requested AGP/Kotlin artifact is absent from the cache. It is not a reason to disable
TLS, certificate checks, repository verification, or dependency resolution.

The AIDL task completed successfully offline in 37 seconds. The full debug build completed online
in 9 minutes 35 seconds while downloading the remaining artifacts, then subsequent work reused
the Gradle build cache. No repository, timeout, or security setting was weakened.

## Code fix validated by the scale test

Large sync batches queried retained-trash settings with one `IN` clause containing 100,000
parameters. SQLite rejected that statement with `too many SQL variables`. The query now uses the
existing `kDriftMaxChunk` (32,000) limit and executes bounded chunks. This preserves the same
results while keeping every statement below SQLite's host-parameter limit.

## Validation

- `flutter build apk --debug --no-pub`: successful.
- `apksigner verify --verbose`: v2 signature valid, one signer.
- `aapt dump badging`: package `de.opennoodle.gallery.debug`, versionCode 11,
  versionName `5.7.3-DEBUG`, compile/target SDK 36.
- `sync_stream_repository_test.dart`: 97 tests passed.
- Synthetic shared-space scale suite: 4 tests passed with 100,000 rows per scenario.
  No production database or media was used.

The APK and SHA256 sidecar are stored in the task artifact directory, outside the repository:

`/mnt/hp-data/codex-work/gallery-auto/20261016-092107-3580683/artifacts/gallery-debug.apk`

