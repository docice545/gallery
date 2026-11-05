# Verified free-space removal

The local query previously admitted a remote index tombstone as a backup. The real SQLite regression failed before the correction. Removal candidates now exclude tombstones, retain their server identity, and carry per-file size estimates.

FOTO rechecks the reviewed IDs, owner, hash, current server metadata and actual original HEAD response before calling the native removal API. Both server components must be available for a local Live Photo. Album exclusions, favorites, local revisions and playback style are checked again after the network wait. A changed account/server/filter, verification failure, missing original, or partial native acknowledgement cannot authorize another batch. Unacknowledged files remain selected; there is no automatic destructive retry. Date/filter changes invalidate a stale confirmation and scan.

The 105-test regression includes real SQLite candidate selection plus API, service, notifier and widget checks. The separate four visual tests render the actual settings widget in Russian/English and both themes with synthetic file identities and mocked receipts. The reviewed PNGs show the verification explanation, localized date, complete button label, and one retained file after a partial result. The toast is asserted through its service mock; these PNGs do not prove native permission handling.

Reproduce from `mobile/` after the normal code-generation steps:

```sh
flutter test --no-pub test/providers/cleanup_provider_test.dart test/repositories/verified_backup_api_test.dart test/services/verified_cleanup_service_test.dart test/services/cleanup.service_test.dart test/medium/repositories/local_asset_repository_test.dart test/presentation/pages/cleanup_preview_page_test.dart test/presentation/pages/instant_trash_cleanup_test.dart test/presentation/pages/free_space_verification_test.dart --reporter expanded
FOTO_FREE_SPACE_EVIDENCE=/tmp/foto-free-space flutter test --no-pub test/presentation/pages/free_space_verification_test.dart --reporter expanded
flutter analyze --no-pub
```

`receipts.json` records executed results and local log hashes. Native Android/iOS removal, permission denial, iCloud originals, actual bytes reclaimed after emptying system trash and backup restoration remain **DEVICE_REQUIRED**. Server-original availability must also be checked against the HP instance before acceptance. These are readiness checks, not final product acceptance.

The final wording also removes the duplicated keep verb (Russian: “Оставить: Избранное, 11 альбомов”), replaces the technical cutoff label with “Фото и видео до даты”, explains why a date is required, and calls the scan results copies **to verify**. The network/Live Photo verification explanation remains visible on the final review step. The four final visual fixtures follow main.dart’s locale bridge for ICU plurals; eight notifier checks also passed in that run.
