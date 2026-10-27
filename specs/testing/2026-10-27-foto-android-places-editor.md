# FOTO Android — Places, Russian names and editor verification

Date: 2026-10-27. Source branch: `codex/foto-android-places-editor`.
Verified base: `ebdba46a90f52c16d42546f20073d5bf0e4afd4f`. Implementation HEAD: `bdd58a7a00ffcf22db9fa88ad0c1555f3f1a1fc4`.

## Scope and preceding functionality

Android source changes only. MapLibre, OpenFreeMap color helpers, photo clusters, PlaceNameService/native Geocoder/cache, copy-only custom editor/history and Magic Eraser already existed. The earlier Hawaii constant removal was preserved, not repeated. No backend, sync, deletion, originals, EXIF, schema, API, signing, APK/version or production change was performed. No HP/NAS/SSH/phone access or deployment.

## Confirmed defects and changes

- Map initially followed one newest photo instead of the library extent. SQLite computes matching geographic bounds without materializing the library in Dart, including the shortest longitude arc. Map fitting waits for native/style readiness and respects later user gestures. Empty GPS has a neutral state; subsequent first geotag can fit. Previews render actual clusters and retain the native map through reload. Optional marker/label failures no longer leave a gray overlay; generation cleanup no longer cancels its replacement.
- Default style uses OpenFreeMap Liberty in light mode and Fiord in dark mode; custom URL/JSON sources are preserved. Photo extent includes all test points while the existing 10000 displayed-marker cap is retained.
- Russian candidates are validated individually and ranked by distance to the actual photo coordinates. Trusted display-only cache v3 validates both fresh and restored labels and isolates owner/endpoint/locale/exact coordinates. Old-session writes and alias HTTP requests are retired; queues and caches are bounded. No transliteration or place-name replacement table.
- Places retain raw city/state/country identity through list keys, search, detail titles and read-only timeline predicates. Original names and coordinates are unchanged.
- Map label rewriting preserves authored expressions, refs, formatting and fallback. Independent MapLibre style-spec validation reproduced the old null-first expression error `Expected null but found value instead`; string-typed first-nonempty expressions fix it. Repeated language changes do not accumulate wrappers.
- Editor now exposes Crop, Markup, Text and Magic Eraser, plus Back/Undo/Redo/Save copy. Dark responsive panels support portrait/landscape, safe insets and enlarged text. Filters/stickers/layers/reset remain secondary capabilities. A shared finite, bounded straighten geometry drives preview, pointer mapping and full-resolution copy export; history includes fine angle and batches one slider gesture.
- Magic Eraser directly opens the existing original-based server workflow. Availability/retry reasons are visible and route opening is guarded against double taps. Crop/markup drafts and redo remain unchanged on cancel and on AI-copy save. Current unsaved edits are not submitted to AI because the existing API accepts the original; the UI states this explicitly. AI produces its existing separate server copy. Parent editor save remains copy-only and does not overwrite the original or introduce automatic uploads.

## Validation

- Combined Flutter unit/widget/repository/golden regression: **664 passed, 0 failed**. Goldens compared normally after intentional visual review, without update mode. Targets and logs are archived outside the repository.
- Last navigation-lifecycle cleanup: **46 tests passed**, including reentrant Magic Eraser, draft/redo preservation, unavailable/retry and copy flows.
- Final whole `flutter analyze --no-pub`: **No issues found**.
- Final Android JVM `:app:testDebugUnitTest`: **85 tests / 8 suites, 0 failures/errors/skips; BUILD SUCCESSFUL** (cached native tasks accepted; no APK signing/packaging).
- Real Dart-produced styles checked by `@maplibre/maplibre-gl-style-spec@26.4.1`: **18 full styles, 18 evaluated expressions, 1800 repeated locale changes passed**; no live network/native map rendering.
- All 10 changed locale JSON files pass Prettier; `git diff --check` passes. Flutter 3.47.2 / Dart 3.13.2 / JDK 21 / cached project SDK and dependencies. No dependency version or lockfile changes.

## Physical verification and remaining limits

There is no Android emulator/system image, /dev/kvm or physical Samsung in this cloud environment. Golden PNGs are **headless Flutter widget renders with project fonts and synthetic imagery**, not screenshots from Android or Samsung.

Live OpenFreeMap tile/glyph access is unavailable under the cloud network policy. Fiord is marked unfinished upstream; actual native map rendering and network quality must be checked on the device. Android Geocoder may lack Russian names or ignore locale. Unsupported raster/custom sources and untrusted results correctly retain original names; administrative captions may retain original spelling. No claim of universal Russian geographic coverage.

Same-name places with identical raw city/state/country cannot be split reliably without an authoritative geographic identity. The existing read-only Places API lacks that ID; no guessed spatial grid, database rename or backend change was introduced. If observed on real data, a separately approved minimal read-only place identity/alternate-name API can be evaluated.

Samsung checks: cold/repeated map open; actual library bounds and noGPS; custom sources, light/dark, weak network; Russian/app-language switching across list/search/detail/map; coordinate-disambiguated Annino/Khimki/Khot'kovo/Druzhba/Belek and requested locations. Check editor portrait/landscape, gesture navigation/cutouts/large fonts, crop/straighten/markup/text, undo/redo, copy save, and Magic Eraser unavailable/retry/cancel/success preserving drafts using a synthetic test image. No real originals should be modified for validation.

No APK is produced or declared ready in this source stage. No production action is needed to review the code; release and physical Samsung acceptance remain separate decisions. Rollback of an eventual mobile release uses the existing signed release process; this branch does not change server/data formats.

## Commits

```text
fbf21ec61aea3c9e4759aac91ab40b0e9d4a7281 fix(mobile): fit photo maps and restore native map lifecycle
9d97429c7c6d5eab06225aeba60250e26bf91dfa fix(mobile): scope trusted place names to the active session
38364cf95e4641435daf64be9089d65dcad6e964 fix(mobile): keep Places tied to their source geographic context
485c9f4538521fd111202a0f4b8e8d3a2910006f fix(mobile): preserve valid localized map label expressions
11d74989dcfb72b2267212def8820ef8079fc99f feat(mobile): share straighten geometry with copy exports
bdd58a7a00ffcf22db9fa88ad0c1555f3f1a1fc4 fix(mobile): simplify photo editing into four accessible tools
```

## Changed files

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
- `mobile/android/app/src/main/kotlin/app/alextran/immich/places/PlaceNamePolicy.kt`
- `mobile/android/app/src/main/kotlin/app/alextran/immich/places/PlaceNamesPlugin.kt`
- `mobile/android/app/src/test/kotlin/app/alextran/immich/places/PlaceNamePolicyTest.kt`
- `mobile/lib/domain/models/map.model.dart`
- `mobile/lib/domain/models/place.model.dart`
- `mobile/lib/domain/services/map.service.dart`
- `mobile/lib/domain/services/place_name.service.dart`
- `mobile/lib/domain/services/timeline.service.dart`
- `mobile/lib/infrastructure/repositories/map.repository.dart`
- `mobile/lib/infrastructure/repositories/remote_asset.repository.dart`
- `mobile/lib/infrastructure/repositories/timeline.repository.dart`
- `mobile/lib/presentation/pages/edit/edit.page.dart`
- `mobile/lib/presentation/pages/edit/editor.provider.dart`
- `mobile/lib/presentation/pages/edit/editor_mode.dart`
- `mobile/lib/presentation/pages/edit/magic_eraser.page.dart`
- `mobile/lib/presentation/pages/edit/widgets/filtered_image.dart`
- `mobile/lib/presentation/pages/place.page.dart`
- `mobile/lib/presentation/pages/place_detail.page.dart`
- `mobile/lib/presentation/widgets/map/library_map_preview.widget.dart`
- `mobile/lib/presentation/widgets/map/map.widget.dart`
- `mobile/lib/presentation/widgets/map/map_viewport.dart`
- `mobile/lib/presentation/widgets/map/place_list_tile.widget.dart`
- `mobile/lib/providers/infrastructure/map.provider.dart`
- `mobile/lib/providers/map/map_state.provider.dart`
- `mobile/lib/providers/place_names.provider.dart`
- `mobile/lib/routing/router.dart`
- `mobile/lib/utils/edited_image_exporter.dart`
- `mobile/lib/utils/editor_geometry.dart`
- `mobile/lib/utils/place_names.dart`
- `mobile/lib/widgets/map/map_style_presentation.dart`
- `mobile/lib/widgets/map/map_theme_override.dart`
- `mobile/lib/widgets/map/map_thumbnail.dart`
- `mobile/test/domain/models/place_test.dart`
- `mobile/test/domain/services/place_name_service_test.dart`
- `mobile/test/domain/services/timeline_factory_temporal_scope_test.dart`
- `mobile/test/infrastructure/repositories/map_repository_test.dart`
- `mobile/test/infrastructure/repositories/place_repository_test.dart`
- `mobile/test/infrastructure/repositories/timeline_place_identity_repository_test.dart`
- `mobile/test/modules/map/map_theme_override_test.dart`
- `mobile/test/pages/edit/editor_acceptance_test.dart`
- `mobile/test/pages/edit/editor_compact_layout_test.dart`
- `mobile/test/pages/edit/editor_save_retry_test.dart`
- `mobile/test/pages/edit/goldens/compact_android_portrait.png`
- `mobile/test/pages/edit/goldens/compact_android_portrait_draw.png`
- `mobile/test/pages/edit/goldens/compact_ios_portrait.png`
- `mobile/test/pages/edit/goldens/compact_ios_portrait_draw.png`
- `mobile/test/pages/edit/goldens/compact_landscape.png`
- `mobile/test/pages/edit/goldens/compact_landscape_draw.png`
- `mobile/test/pages/edit/goldens/editor_ru_compact_large_text.png`
- `mobile/test/pages/edit/goldens/editor_ru_draw_portrait.png`
- `mobile/test/pages/edit/goldens/editor_ru_drawing_tools.png`
- `mobile/test/pages/edit/goldens/editor_ru_text_landscape.png`
- `mobile/test/pages/edit/magic_eraser_editor_integration_test.dart`
- `mobile/test/pages/edit/magic_eraser_page_test.dart`
- `mobile/test/presentation/widgets/map/library_map_preview_test.dart`
- `mobile/test/presentation/widgets/map/map_source_provider_test.dart`
- `mobile/test/presentation/widgets/map/map_style_presentation_test.dart`
- `mobile/test/presentation/widgets/map/map_thumbnail_lifecycle_test.dart`
- `mobile/test/presentation/widgets/map/map_viewport_test.dart`
- `mobile/test/presentation/widgets/map/place_list_tile_test.dart`
- `mobile/test/providers/place_names_provider_test.dart`
- `mobile/test/providers/place_names_session_provider_test.dart`
- `mobile/test/unit/providers/editor_document_history_test.dart`
- `mobile/test/utils/edited_image_exporter_test.dart`
- `mobile/test/utils/editor_geometry_test.dart`
- `mobile/test/utils/place_names_test.dart`
