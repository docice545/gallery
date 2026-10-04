# Dense mobile Photos timeline

The main mobile timeline opts into `Timeline.denseLayout`. Album, picker and
tablet grids retain their existing geometry. Date/month headers, overview modes,
filters, stack handling and asset navigation continue to use the same timeline
service, segments, rows and thumbnail widgets.

`FixedRowLayout` computes row counts, asset ranges, heights and offsets from the
bucket count and existing column preference. It balances assets across those rows
(for example five assets with four columns becomes three plus two), avoiding a
sparse trailing row. A singleton fills the viewport width with height limited to
75% of the width and 360 logical pixels. Other rows share the full width with
height limited to the square pitch for their item count and 280 logical pixels.
Loaded row widths are proportional to existing asset aspect ratios, bounded to
0.65–1.65, with a 72px minimum allocation when the column preference permits it
to retain badge/selection space; unknown/malformed dimensions use a square fallback. Cover cropping
keeps the row coherent. The final tile absorbs floating-point rounding.

Heights and row asset ranges are available before assets load, so loading only
changes horizontal allocation, never the vertical scroll extent. Placeholders
fill the same width and retain the same height. Rows still load through the
existing bounded `TimelineService` buffer and fast-scroll deferred-loading path.
No per-thumbnail metadata request, new asset model or full-resolution image load
is added. Remote thumbnail decode sizes remain bounded to their rendered physical
tile dimensions. Row-offset lookup uses binary search without per-asset lists;
asset-to-row mapping is constant-time. Scroll jumps and pinch/grouping restoration
use these mappings, including the rebalanced final rows.

The live-photo scope continues measuring actual rendered tile rectangles against
its viewport. It does not assume square tiles or equal widths. Eligibility stays
at 80% visibility; settling remains 350 ms, muted, one active native player, one
playback, no looping/cascade. A further play requires real scroll displacement of
at least `max(96px, previousViewportHeight * 0.25)` and a different asset.
Geometry-only changes do not replenish that budget. Controllers/streams are not
created for static rows; the thumbnail, gestures, Hero and badges remain the
existing widgets.

Focused tests cover full-width single/two/multiple rows, mixed and malformed
dimensions, deterministic row mappings, segment/header offsets, stack/cloud/live
badges, long-press/multiselect/selection insets/Hero, central candidate selection,
the visibility threshold, completion without cascade, and scroll cancellation
with the meaningful-new-viewport rule. Device checks remain necessary for scroll
smoothness and native Motion/Live playback on Samsung and iPhone.

Mobile branding uses the existing i18n loader with an explicitly scoped product
prose adapter. `app_name` is `Фото` for Russian and `Photos` for English/other
locales, with English fallback for translator-owned locales. Technical identifiers,
URLs and generic gallery terminology are preserved. Login/start and About/license
surfaces use this key; the timeline app bar reuses the existing colorful mark with
a localized text title instead of a baked-in SVG wordmark. The adapter also works
after the official release branding overlay, which can still supply Noodle
Gallery prose for the web. Android/iOS product identifiers and launcher display
names from the earlier custom commits are retained.

HP installation/build commands are in
[the HP runbook](testing/2026-10-04-photos-hp-build.md). Server release metadata is
documented separately in
[the version design](2026-10-04-server-release-version-design.md).
