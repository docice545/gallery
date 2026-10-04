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

## Persistent decisions

`stack_suppression` is owner-scoped and keyed by asset. Dissolving a stack records every member;
detaching a member records that member. Both record and mutation are one transaction. Automatic
creation expands merged stacks, checks suppression, and shares the owner advisory lock with manual
decisions. Manual creation bypasses suppression without clearing it. This intentionally conservative
policy excludes those photos from all future automatic stacks, rather than only one exact set.
The cache badge uses one grouped Drift stream including primaries, refreshed by stack writes/sync.
It cannot reflect remote edits before those edits have synchronized.

New stack creation requires actual ownership of every selected and expanded asset. Shared-space
editor permission alone does not transfer ownership or authorize another user's persistent decisions.
Legacy mixed-owner stacks can be dissolved without deleting photographs; only the caller's own
members acquire suppression. Removing a foreign member is rejected. Review such legacy groups on
staging before integration; do not silently transfer ownership or write another owner's suppression.

`memory_candidate` is a separate decision record referencing an ordinary memory. It does not add
a memory type. A candidate's owner, canonical asset fingerprint, membership and decision remain
after the underlying memory expires/is removed. Exact creation retries are idempotent; dismissed
fingerprints cannot recur. A Jaccard overlap of at least 0.8 rejects nearly identical proposals,
including altered order/primary. This is asset-based deduplication, not visual/semantic AI comparison.
The external generator must additionally deduplicate visually equivalent exports/new asset IDs.

Pending candidates are omitted from normal memory search/statistics and overlap reconciliation,
protected from age-based cleanup, and filtered from mobile offline fallback. Save marks the same
memory permanent, clears its expiry and makes it visible now; dismiss soft-deletes it while retaining
the decision record; later stores a reminder one day later. Decisions are locked and owner-scoped.
Terminal decisions are idempotent and cannot silently be reversed by a stale device. Creation uses
the existing Custom notification and websocket infrastructure. Mobile supplies an in-app card and
polls due candidates while the lane is mounted; background push delivery is not assumed.
Due listing applies the ordinary hidden timeline scope and filters empty/removed proposals before
the delivery limit. Saving a proposal whose memory was removed returns conflict and retains history.

## Production integration required

No production endpoint or script was contacted or edited. These changes must be reviewed and
deployed separately; the current production 5.7.1 does not acquire new APIs merely by installing
the mobile client. Validate against a staging copy of that version before deployment.

### Database and server

New fork migrations, in `server/src/schema/migrations-gallery/ORDER`:

* `1791070000000-AddStackSuppression`: additive table, cascading cleanup only when the owner/asset
  is deleted. Down drops decisions but neither stacks nor photographs.
* `1791071000000-AddMemoryCandidates`: additive decision table with owner/fingerprint uniqueness
  and a nullable reference to memory. Down removes unsaved proposals and drops the decision table;
  saved ordinary memories and all photographs survive. Export decisions before a production rollback
  if they must be recovered. No existing memory type or generation state is removed on upgrade.

Use Gallery's normal startup migration path for an existing database, not schema reset and not the
fresh-database-only CLI ordered migration path described in AGENTS.md. Rehearse rollback on staging.
OpenAPI and the TypeScript/Dart clients must be regenerated from the matching server commit.

### Existing automatic stack maintenance

1. Fetch `GET /api/stacks/suppressions?page=1`, incrementing pages until fewer than 1000 entries
   arrive. Entries contain `assetId` for the authenticated owner only. Cache per maintenance pass,
   never globally across owners.
2. Exclude those assets from automatic grouping, regrouping, merging and automatic primary changes.
   Do not dissolve/rewrite a manually restored stack containing suppressed assets.
3. Send `automatic: true` in every automatic `POST /api/stacks` body, alongside the existing
   `assetIds`. Treat HTTP 400 suppression as a user decision, not a transient failure to retry.
   The server also checks children expanded from existing primaries, atomically.
4. A script writing SQL directly must use the same transaction lock
   `pg_advisory_xact_lock(hashtext(ownerId), 179107)` and check `stack_suppression` again inside
   the transaction before mutating *any* member. Prefer the API. Reading the list once then writing
   SQL without a transactional recheck leaves a race with a user's removal.

Ordinary client/manual `POST /stacks` omits `automatic`; manual regrouping remains available.
No automatic opt-in was applied to unknown existing production scripts.

### Existing AI generation and carousel management

* Continue the existing AI provider/model/key handling on the server-side process. No mobile key
  or new generator is added. Preserve existing rule IDs, dedupe keys, memory data and memory types.
* Before generating prose, inspect existing `title`/`subtitle` or `data.title`/`data.subtitle`.
  Preserve populated AI metadata. For an existing plain on_this_day or rule memory, enrich its
  existing ID with `PUT /api/memories/{id}` and body
  `{"title":"День у моря","subtitle":"Тёплый день вместе у воды"}`. This atomically merges only
  display fields into JSONB; year, context, rule identity, assets and dates remain unchanged.
  Sending null clears that one display field and restores the normal localized fallback.
* For a new proposal, use `POST /api/memories/candidates` with the ordinary existing type/data,
  `memoryAt` and a nonempty `assetIds` array. Do not set isSaved=true. For rule candidates, continue
  your existing external AI ruleId/dedupeKey, plus title/subtitle inside data. The operation runs as
  the target owner via a appropriately scoped existing API identity, never arbitrary ownerId input.
  Keep external AI rule identities distinct from built-in rules: pending rows can participate in
  the existing generation deduplication checks. For standard on_this_day/month-recap content, prefer
  enrichment of its existing memory ID rather than reserving its built-in generation identity.
* A successful response contains candidate `id`, `state` and the ordinary `memory`. Retry the same
  asset set safely. HTTP 409 means declined/similar/already-existing content; do not bypass it by
  reordering assets, changing primary or switching back to POST /memories. When a normal memory
  already exists, enrich that ID instead. Compare semantics/visual similarity in your AI process too.
* Read due proposals with `GET /api/memories/candidates`; record actions with
  `POST /api/memories/candidates/{candidateId}/decision` and
  `{"action":"save"}`, `{"action":"dismiss"}` or `{"action":"later"}`. The later delay is one day.
  Do not change candidate state through ordinary isSaved updates or recreate declined candidates.
* Use ordinary `GET /api/memories` for the carousel: it excludes undecided/declined candidates.
  A direct-SQL carousel must exclude a memory whenever a corresponding memory_candidate row has
  state other than saved. Do not rewrite a saved candidate's assets/showAt/hideAt or clear isSaved.
  Preserve unknown/external memory rules as the current reconciliation already does.
* Custom notifications use `data.memoryCandidateId`. Existing web notification delivery is reused;
  guaranteed OS background alerts require a separately configured push service. The mobile card
  remains usable without push and an older server's missing candidates endpoint is optional.

## Rebase risks and native acceptance

Localized touch points are the two standard services/repositories/DTOs, shared SDK generation,
mobile memory/photo widgets and action menus, plus two fork migrations/tables. Watch upstream
PhotoView gesture changes, stack removal/merge contracts and memory search/cleanup/reconciliation.
Regenerate clients, rather than resolving generated SDK conflicts by hand. Keep migration timestamps
and ORDER stable after deployment. Native package/bundle IDs and signing/app-group settings remain
unchanged; this preserves existing link/backup/share integration rather than creating new domains.

Before the first APK, complete Flutter static analysis/widget tests, verify Android SDK/NDK/JDK pins,
generate Drift/freezed/translation artifacts, and build an unsigned debug APK using the existing app.
Real devices must test pinch-vs-page arbitration, stack synchronization across Android/iOS/web,
PhotoKit limited access, Samsung battery restrictions, share/open/import/save and OS notifications.
iOS compilation/signing requires macOS/Xcode; neither an IPA nor an OS background scheduling
guarantee can be established by Linux widget tests.
