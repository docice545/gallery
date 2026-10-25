# FOTO Build 19: Android Places and map validation

See [the design and backend localization boundary](../2026-10-25-foto-build19-android-places-design.md).

## Implemented

- The original place name stays the asset-filter identity. Read-only local EXIF
  supplies a representative preview and coordinates; optional system geocoder
  lookup supplies a localized display name. The queue/cache are bounded and
  survive app restarts; expired or unavailable results fall back to the original
  name without transliteration. A hung provider cannot accumulate OS requests.
- Russian sorting/search handles case and Ё. Both localized and source names
  remain searchable. Settled searches can use the existing authenticated GeoNames
  alias endpoint; obsolete requests are canceled. Previews and routes are kept.
- Known default monochrome OpenFreeMap styles use its key-free Liberty style.
  Custom providers are retained. Geographic vector labels prefer the app locale,
  then native names and the authored fallback. Native tile caching is retained.
- Crisp native clusters show counts, split on zoom and select photo bounds from
  their current leaves. Stale source/tap operations are discarded. The existing
  10,000-marker query cap is unchanged. Missing/invalid GPS is excluded without
  rewriting it; real zero coordinates remain valid.
- A compact count/handle panel expands on tap, drag or marker selection. The
  photo grid unmounts while collapsed, and the grouping selector occupies measured
  space below it. SafeArea, external controller ownership and keyboard geometry
  are tested.

## Verification

Final combined Android regression: **304 passed, 0 failed, 1 pre-existing skip**,
including new name/search/cache/provider/database/cluster/panel tests and the
existing editor/Trash/Live Photo regressions. Full Flutter analyze reports no
issues. All **71 Android JVM tests** pass, including nine synthetic localized-name
policy tests and compilation of the actual Android Geocoder plugin. No Drift
schema version or migration changes are needed for the existing store-table cache.

Fixtures exercise Москва, Химки, Внуково, Белек, Муйне, Немчиновка, Восточное
Дегунино, Новая Купавна and Гонолулу, rejected airport/POI/distant matches,
unsupported locale/provider, restart, negative cache, queue bounds, no-GPS and
date-line selection. These tests prove policy and application logic; they do not
prove responses from a live Samsung geocoder or native MapLibre rendering.

## Owner acceptance still required

- Real Russian labels and glyphs for the listed locations at several zoom levels.
  The cloud proxy returned HTTP 403 for the public style; its live payload was
  not verified. A custom raster tile provider cannot translate baked-in labels.
- Actual provider availability/offline recovery, tile cache/network traffic,
  cluster hit testing/zoom and photo selection on Samsung.
- One UI portrait/landscape, large font, gesture navigation, keyboard and scrolling
  with a large library. No emulator/system image or physical Samsung is available
  here; no emulator screenshot or device confirmation is claimed.
- Sign any new Android candidate only with the existing production key on HP and
  verify its certificate and update over the installed app before distribution.

No production backend, PostgreSQL/Redis, NAS originals, GPS/EXIF values, signing
keys or network/Compose settings were modified. No deployment, mass sync or
real-media operation was run. The design documents an optional language-tagged
server geodata proposal only; it is not implemented or authorized for production.
