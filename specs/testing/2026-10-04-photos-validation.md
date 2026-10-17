# Фото: validation and changed files

Starting branch: `work`, synchronized with `origin/work` at
`07f7a8a8e98a52ba7bcd70a30c3b8018a00775c0`. Previous custom history is preserved.

Implemented: dense/full-width main mobile timeline with deterministic lazy row
geometry; actual server release manifest stamping via Docker `BUILD_VERSION`;
localized mobile product branding (`Фото` / `Photos`). Existing one-shot autoplay,
Memories zoom, stack badges/manual management/suppression, candidate workflow,
system integration, IDs and production scripts are preserved.

## Executed validation

- Flutter 3.47.2 / Dart 3.13.2: **501 tests passed**, zero failed, final runner exit 0.
  This includes the entire timeline widget suite, main page/zoom/memory lane/infinite
  scrolling/filter grouping, dense row geometry/badges/selection/autoplay, Memories
  zoom/candidates/titles, manual stack APIs/actions, sharing/editing, settings,
  thumbnail/native preview plumbing, foreground/background upload, server-info,
  compatibility/SemVer, branding/toolbar and location disclosure tests.
- Entire mobile `dart analyze --fatal-infos`: **No issues found**, exit 0.
- `dart format --output=none --set-exit-if-changed` on all 28 changed/new Dart files:
  zero changes, exit 0.
- Server unit/controller tests: version-release, version, server information and
  stack services: **102 passed (4 files)**; memory service: **92 passed (1 file)**.
  Total **194 passed**, zero failed. The public version endpoint, About metadata,
  WebSocket current/latest version and real update notifications are exercised.
- `pnpm run test:build-version`: **6 passed**, zero failed. Covers release stamp,
  official v-prefix, future/RC versions, existing stamped manifests, development
  fallback and invalid input failing without modifying the manifest.
- A disposable runtime-directory fixture copied the built `dist/constants.js`
  and executed the real CLI stamp; compiled `serverVersion` resolved to **5.7.1**.
  The source package remains 3.2.0; only the image/runtime manifest is stamped.
- Server `pnpm run check` and `pnpm run build`: passed, including migration-copy
  postbuild. No migration source or database schema was changed.
- ESLint for the added TypeScript service/controller tests: passed.
- Prettier for changed server/JSON/workflow/spec files and all 10 maintained
  locale files: passed. Existing i18n branding regression script passed across
  89 locale files; mobile adapter tests verify pre/post-release product prose,
  Russian/English/other fallback names and preservation of URLs/identifiers.
- `Info.plist` parses; existing `CFBundleDisplayName` remains `Фото`.
- HP command blocks pass `bash -n`; the APK metadata parser was checked with a
  representative aapt package/version line. Production commands were not run.
- Whitespace check passed with the repository's existing CRLF endings accepted.
  Android build files/IDs, dependencies, lockfiles, database/schema files are
  unchanged relative to the starting commit.

## Existing diagnostics and unperformed checks

Full server `pnpm run lint` and `pnpm run format` **fail** on the pre-existing
`server/src/schema/migrations-gallery/1793400000000-FixMemoryCandidateSchema.ts`:
ESLint reports two `prettier/prettier` errors on lines 6–7, and Prettier flags that
same file. It is byte-identical to the starting commit; it was intentionally not
rewritten under the task's migration constraint. Changed files pass their checks.

The final passing mobile runner printed 9 occurrences of the already-observed
`dart_isolate.cc(1403)` / callbacks-prohibited diagnostic during native VM teardown;
there were no failed assertions or nonzero runner exit. The earlier baseline
validation also observed this diagnostic. Server tests emit the existing Node
experimental WASI warning. Codegen emits the pinned analyzer language-version
warning (3.12 analyzer vs 3.13 Dart); dependencies were not upgraded.

Android SDK is unavailable in this Cloud environment: no native APK was built or
signed here. macOS/Xcode/iPhone are unavailable: no iOS archive or physical Live
Photo verification ran. DCM keys are absent. The complete multi-stage Docker image
was not built in Cloud; manifest stamping, compiled version propagation and HTTP
controller behavior were validated locally. No production endpoint, container,
external AI Memories/carousel/auto-stack file or deployment was accessed.

On Samsung, verify full-width/portrait/landscape layouts, filters, pinch/grouping,
fast scroll/pagination, selection/stacks/badges/tap/Hero and the silent one-shot
Motion Photo behavior, including no cascade/restart in the same viewport. Measure
scroll smoothness/RAM/network on device. On iPhone, verify native paired Live
Photo, selection/navigation and permission/launcher branding with Xcode/macOS.

Exact HP commands, including server-only recreation and APK 5.7.2 build 2/signature
verification, are in [the runbook](2026-10-04-photos-hp-build.md). Required server
argument: `BUILD_VERSION=5.7.1`; custom source links use
`BUILD_REPOSITORY=docice545/gallery`. No runtime version variable is required. API
routes/DTOs and database migrations/schema are unchanged. External production
systems require no changes for these three features.

## Changed files

### Timeline layout

- `mobile/lib/presentation/pages/dev/main_timeline.page.dart`
- `mobile/lib/presentation/widgets/timeline/fixed/row_layout.dart`
- `mobile/lib/presentation/widgets/timeline/fixed/segment.model.dart`
- `mobile/lib/presentation/widgets/timeline/fixed/segment_builder.dart`
- `mobile/lib/presentation/widgets/timeline/segment.model.dart`
- `mobile/lib/presentation/widgets/timeline/timeline.state.dart`
- `mobile/lib/presentation/widgets/timeline/timeline.widget.dart`
- `mobile/lib/presentation/widgets/timeline/timeline_scroll_target.dart`
- `mobile/test/presentation/widgets/timeline/dense_row_layout_test.dart`
- `mobile/test/presentation/widgets/timeline/dense_timeline_overlays_test.dart`
- `specs/2026-10-04-dense-mobile-timeline-design.md`

### Version reporting

- `.github/workflows/gallery-release-server-only.yml`
- `mobile/lib/providers/server_info.provider.dart`
- `mobile/test/modules/utils/version_compatibility_test.dart`
- `mobile/test/providers/server_info_provider_test.dart`
- `server/Dockerfile`
- `server/bin/set-build-version.mjs`
- `server/bin/set-build-version.test.mjs`
- `server/package.json`
- `server/src/services/version-release.service.spec.ts`
- `specs/2026-10-04-server-release-version-design.md`

### Branding

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
- `mobile/ios/Runner/Info.plist`
- `mobile/lib/constants/constants.dart`
- `mobile/lib/main.dart`
- `mobile/lib/pages/common/splash_screen.page.dart`
- `mobile/lib/services/immich_logger.service.dart`
- `mobile/lib/services/localization.service.dart`
- `mobile/lib/utils/app_asset_loader.dart`
- `mobile/lib/widgets/common/app_bar_dialog/app_bar_dialog.dart`
- `mobile/lib/widgets/common/app_logo_with_text.dart`
- `mobile/lib/widgets/common/immich_sliver_app_bar.dart`
- `mobile/lib/widgets/common/immich_title_text.dart`
- `mobile/lib/widgets/settings/beta_sync_settings/sync_status_and_actions.dart`
- `mobile/test/policy/app_title_branding_test.dart`
- `mobile/test/policy/location_disclosure_copy_test.dart`
- `mobile/test/widgets/common/immich_sliver_app_bar_logo_test.dart`
- `mobile/test/widgets/common/photos_branding_test.dart`

### Shared runbook and validation

- `specs/testing/2026-10-04-photos-hp-build.md`

- `specs/testing/2026-10-04-photos-validation.md` (this report).
