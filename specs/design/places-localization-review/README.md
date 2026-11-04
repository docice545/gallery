# Build 37: one localized place label

The source identifier is **not** the translated label. `Place.scopeIdentity` remains `(name, state, country)`; coordinates and the representative asset ID remain unchanged. Timeline queries still use the original source tuple. Album titles and EXIF are not rewritten.

## Cause traced through the actual code

1. `server/src/repositories/map.repository.ts` imports GeoNames canonical `name`; alternate names are an untagged list. `search.repository.ts` can search aliases, but its response does not identify each alias's language. Picking an arbitrary Cyrillic alias would not establish that it is Russian.
2. The mobile Places list previously used `localizedPlaceNameFallback`, whereas `PlaceDetailPage` used an asynchronous result or the raw route name. An unavailable geocoder therefore produced **Аннино → Annino** without changing the selected group.
3. The existing offline catalog recognized `Vostochnoye Degunino`, while the screenshot contains the other attested source spelling `Vostochnoe Degunino`. The user-confirmed Russian name is now available for both. This is an explicit alias, not a transliteration rule. The screenshot alone does not prove which native geocoder error occurred on that Samsung.
4. Timeline used raw EXIF city text independently of the Places cache.

## Shared display path

`PlaceDisplayNames` / `placeDisplayNamesProvider` now choose a trusted cached label for the app locale, then a previously confirmed offline name, then the original name. Cards, their localized search, the opened place and the existing floating Timeline date indicator all use this policy. The cache index is rebuilt when the locale/cache changes, not for every frame. A geographic scope can reuse a cached label from another representative photo only when the cached labels agree; conflicting homonyms fall back without guessing.

The existing cache still separates language, owner and server endpoint, rejects retired sessions, and limits persisted entries. Opening Places may enrich at most twelve opening places; explicitly opening a detail may resolve that place. Scrolling tiles performs no geocoder requests. Timeline uses only metadata and this cache. There is no archive re-geocoding job and no change to source place IDs, grouping, coordinates or media.

## Executable evidence

- `mobile/test/utils/place_names_test.dart`: Annino, both Degunino spellings, locale changes, missing/ambiguous translations, source fallback and immutable identity.
- `mobile/test/providers/place_names_session_provider_test.dart`: persisted cache and 200 cache-only display reads without additional native calls; endpoint/owner retirement and cache bounds.
- `mobile/test/infrastructure/repositories/timeline_place_identity_repository_test.dart`: real SQLite membership/buckets before and after ru/en/ru display changes, including same-name places in different regions/countries.
- `mobile/test/presentation/pages/place_localization_test.dart`: actual Places → generated route → detail title, ru/en/ru, localized search, scrolling without per-tile lookup. Optional `FOTO_CAPTURE_PLACES=true` produces four **synthetic Flutter UI renders**, with an offline map and placeholder thumbnails; these are not Samsung screenshots or user photographs.
- Existing scrubber tests retain one fixed, transient, non-interactive indicator and test localized metadata/absence.

CI execution is pending for the new source; see `BUILD37_CHECKLIST.md` for the current result. Real Samsung after-screenshots, offline language switching and native name enrichment remain device acceptance, separately from software tests.
