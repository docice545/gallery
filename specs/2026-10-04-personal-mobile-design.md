# Personal mobile client: architecture and integration

Inspected checkout: `docice545/gallery`, baseline `da5480ae42b77db9cae729f2447ec9b3079ba4a7`.
Production 5.7.1 is a user-supplied compatibility target, not a server contacted during development.

## Existing architecture

Android/iOS share the Flutter application (`mobile/`, Flutter 3.47.2, Dart >=3.12).
Riverpod owns services and presentation state, Drift caches synchronized remote assets/stacks/memories,
auto_route handles navigation. OpenAPI generates the authenticated Dart client. The backend is
NestJS/Kysely/PostgreSQL; web uses SvelteKit and the generated TypeScript SDK.

* Normal asset viewer: `presentation/widgets/asset_viewer/asset_page.widget.dart`; repository-owned
  `widgets/photo_view` implements pinch, double tap, pan and gesture arbitration with PageView.
* Memories: `presentation/pages/memory.page.dart`, nested vertical/horizontal PageViews, progress
  tied to the horizontal controller, photo FullImage and NativeVideoViewer with forced autoplay.
  Photo zoom must replace only the image child and remove the tap overlay that intercepts gestures.
* Timeline: `presentation/widgets/images/thumbnail_tile.widget.dart`; RemoteAsset carries stackId.
  Drift has complete synchronized stack membership; a shared grouped reactive query can provide
  counts without requests per thumbnail. Offline counts reflect the most recent completed sync.
* Stacks: AssetService -> AssetApiRepository -> standard stacks API, then Drift updates. Create
  merges existing stacks when their primaries are selected; delete dissolves without deleting assets;
  update sets primary; removeAsset detaches a non-primary. Current mobile exposes create/dissolve,
  but not a stack picker, member removal or primary selection. Server rejects primary removal;
  mobile must select another primary first, or dissolve a two-member stack.
* Memory model: `memory.data` is JSONB; types remain on_this_day and rule. Rules persist localized
  context (including month_recap), and older/generated prose in data.title/subtitle. Mobile already
  prioritizes data.title; web prioritizes top-level title/subtitle. Server currently mirrors these
  only for rule memories. Update API does not currently enrich data in place. No AI provider or
  key belongs in clients. Existing external AI generation remains the integration point.
* Notifications: server notification repository/websocket events; mobile local notifications and
  background upload notifications. No assumption of a configured push delivery service.
* Backup: selected albums through photo_manager/PhotoKit; domain background worker and native
  Android WorkManager/dataSync foreground service, iOS fetch/processing/background uploader.
  Samsung battery policies and iOS scheduling remain OS constraints.
* Share/export: share_handler import, share_plus outgoing sheet, download/media repositories save
  to device library. Android SEND/SEND_MULTIPLE and content VIEW image/video intents already exist.
  iOS has ShareExtension, library read/add descriptions and app groups. Custom immich links and
  my.immich.app links already exist. Arbitrary self-hosted universal links require domain association
  files and signed entitlements and cannot safely be invented for an unknown production hostname.

## Scope and compatibility decisions

Reuse all existing backup, permission, upload, export and link machinery. Mobile-only features are
zoom, badge, stack controls, display name and import robustness. Persistent suppression and candidate
decisions require server storage. Metadata enrichment can reuse JSONB with an additive API; no new
memory type or replacement AI pipeline. Keep fork migrations separate from upstream migrations.
Do not rewrite server branding or package/bundle identifiers. Production integration is a separate
deployment action; it is not performed by this work.
