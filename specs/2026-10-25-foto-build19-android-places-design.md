# FOTO Build 19: Android places and map presentation

This change is Android presentation and read-only lookup over Build 19. It does
not change backend code, API contracts, production configuration, EXIF, asset
coordinates, originals or server deletion policy.

## Names and identity

The existing Places list reads `remote_exif.city` from the synced local database.
The backend's `MapRepository.reverseGeocode` uses GeoNames primary `name` and
`admin1Name`; its country fallback is English. `MapReverseGeocodeDto` has no
language parameter. The imported comma-separated `alternateNames` are searchable
but do not carry language tags. They cannot reliably select a Russian label.

The new read-only place query also returns the preview's state, country and GPS.
SQLite's sole MAX aggregate keeps those fields with the newest eligible photo.
The original city string remains the route/filter identity. Display translation
must never change group membership or write metadata back to the server.

Visible rows may ask Android's existing system `Geocoder` for a localized forward
lookup of the source city/state/country. It needs no application API key or GPS
permission: the anchor comes from existing synced EXIF. The device's configured
geodata provider can use its network service. Candidates must be within 25 km of
the representative photo and identify a locality/sub-locality. Street addresses,
country/region-only responses and ambiguous POI names are rejected. In particular,
an airport name must not relabel the entire Vnukovo photo group.

The requested language is the app locale. For Russian, a result without Cyrillic
is treated as unsupported. Unavailable, ambiguous, timed-out or offline lookups
leave the source name intact; there is no automatic transliteration. Source names
already in Russian need no lookup. Preview files and coordinates are untouched.

Requests are serial, coalesced and limited to interested mounted rows. A native
request has a 3.5-second deadline; its actual OS slot remains occupied until the
callback returns, preventing a hung provider from accumulating requests. Dart has
a five-second guard and a bounded, user/server/locale/source/GPS-scoped cache in
the existing store table (key 146), with positive and negative TTLs. No Drift
schema change or migration is required. Provider errors log codes without queries
or coordinates. Cache corruption falls back to source names.

Russian sorting handles Ё and case. Search matches both source and display name;
an explicit settled query may also use the existing authenticated GeoNames search
endpoint, matching its primary name and nearby coordinates to existing groups.
Typing, row disposal and route changes cancel obsolete pending work.

Tests for Москва, Химки, Внуково, Белек, Муйне, Немчиновка, Восточное Дегунино,
Новая Купавна and Гонолулу use synthetic localized provider responses. They do
not establish that a particular Samsung geodata provider returns every spelling.

## Color map and photo selection

Keep MapLibre and the existing provider. Only known OpenFreeMap monochrome default
URLs are changed to the same key-free provider's Liberty color style; custom
style URLs remain respected. Native MapLibre keeps responsibility for tile requests
and caching. Geographic vector label expressions prefer the requested language,
then native names, then the authored expression. Route references and numeric
labels remain unchanged. Fonts, halos and collision rules are preserved. Raster
labels cannot be translated because they are baked into tiles.

The cloud proxy returned HTTP 403 for the public Liberty style. Actual style
availability, Cyrillic glyph coverage and weak-network behavior therefore need
device acceptance; JSON fixtures do not prove live tile rendering.

Native GeoJSON clustering replaces blurred circles with crisp outlined markers
and counts. Expansion zoom splits clusters. Selection reads the current native
cluster's leaves and derives tight coordinate bounds for the existing timeline;
source-generation checks discard stale taps. The existing 10,000-marker query
limit remains. Missing, non-finite and out-of-range GPS values are excluded by
read predicates; genuine equator/prime-meridian coordinates remain valid.

The bottom panel starts with its handle and count, avoiding invisible thumbnail
loads. Expansion mounts a scrollable timeline with its grouping selector in a
measured footer. System insets are applied once. External controllers remain
owned by the MapView. Marker selection expands the same panel; camera and
selection generations prevent stale viewport work from replacing that selection.

## Optional future backend localization

No backend change is needed for the client fallback above, and none is included.
If the device provider or tile source lacks Russian names, a minimal server
proposal is an optional locale parameter on a read-only place lookup, backed by
language-tagged GeoNames alternate-name data keyed by GeoNames ID. Retain original
names as fallback and existing EXIF as identity, cache by ID/locale, and preserve
the current endpoint behavior when no locale is requested. Existing untagged
aliases must not be guessed into a language. Import/schema work, data licensing,
API generation and compatibility would require separate review and authorization
before any production use. It must not trigger mass metadata rewriting or media
reprocessing.
