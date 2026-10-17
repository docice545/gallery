# Build 11 upstream compatibility and provenance

Evidence checked on 2026-10-12. This report describes the inherited Build 10
source before the Build 11 changes, and the requirements for validating the final
Build 11 commit. Source inspection, synthetic tests and physical production tests
are different evidence; none substitutes for the others.

## Authoritative repositories and releases

GitHub `GET /repos/docice545/gallery` reports `fork=true`,
`parent.full_name=open-noodle/gallery`, and
`source.full_name=immich-app/immich`. Therefore the immediate authoritative Noodle
Gallery upstream is <https://github.com/open-noodle/gallery>; Immich is its own
upstream, not a replacement repository for this fork.

At inspection the checkout had only the `origin` remote, pointing to
<https://github.com/docice545/gallery.git>. Verified upstream refs were fetched to
`refs/remotes/noodle-verified/*` without changing any working branch. The
`docs/fork/ownership.yml` declaration of an `upstream` remote does not prove that
remote is configured. `AGENTS.md`'s Immich 2.7.5 version is stale; the pinned
release, version metadata and Git graph are the source of truth.

| Official Noodle release                                             | Exact commit                               | Immich baseline | Published UTC       |
| ------------------------------------------------------------------- | ------------------------------------------ | --------------- | ------------------- |
| [5.7.1](https://github.com/open-noodle/gallery/releases/tag/v5.7.1) | `da5480ae42b77db9cae729f2447ec9b3079ba4a7` | 3.2.4           | 2026-09-28 19:01:58 |
| [5.8.0](https://github.com/open-noodle/gallery/releases/tag/v5.8.0) | `37aa54e632606cc6a62bc6bcbba14c62200147c4` | 3.3.1           | 2026-10-12 07:31:44 |

The release API marks both rows non-draft and non-prerelease. The same 5.8.0
commit previously had the 5.8.0-rc.1 tag; its prerelease history does not make the
published 5.8.0 release a prerelease. Git tag refs independently resolve to the
commits above. Stable 5.8.0 is the latest release, not 5.7.3: 5.7.2/5.7.3 in this
repository are local fork release versions.

## Existing fork point and accumulated modifications

The exact Build 11 starting commit is
`3d60f90461511659812eb1341ecda394ba9e1571`. Its merge base with official Noodle
5.7.1 is exactly `da5480ae42b77db9cae729f2447ec9b3079ba4a7`; that official release
is a complete ancestor. There are 138 custom commits, including merge commits,
and zero missing official 5.7.1 commits. The first-parent custom history has 135
commits. At this pinned starting point the diff contains 593 changed files,
82,835 inserted lines and 3,123 removed lines; test fixtures and documentation are
included in those numbers.

The inherited custom surface includes:

- Android/iOS branding and install identities, SideStore-compatible ASCII base
  names and Russian launcher localization; existing signing and delivery tooling.
- Native Android picker/Shizuku integration, local media projection, album actions,
  per-user Library Card Registry, cache/sync handling and backup behavior.
- Timeline grouping/framing, Live/Motion thumbnail autoplay, Trash dates,
  durable local operation revisions and restore acknowledgements.
- Backend Trash/retention guards, durable deletion policies/tombstones/receipts,
  filesystem root/quarantine identity, snapshot/content verification and NFS
  behavior; web/mobile authorization UI.
- Stack suppression, Memories candidate lifecycle and Magic Eraser/inpainting
  extensions. These are existing features, not Build 11 authorization to redesign
  Memories or its external runtime.
- Read-only diagnostics, recovery evidence generation, isolated restore tooling,
  exact image-only deployment/rollback and scoped reconciliation of confirmed
  queued FileDelete jobs.

The complete inherited commit manifest appears below. Build 11 adds its own
reviewed commits after the pinned starting point; use the final release SHA in
artifact provenance, not this historical manifest's upper bound.

## Schema and API compatibility facts

Compared with official 5.7.1 at the pinned starting commit:

- All 97 tracked entries under `server/src/schema/migrations/` are byte-identical
  (96 migration source files plus `ORDER`). Upstream migration history is preserved.
- The existing 68 entries under `migrations-gallery/` become 73: five custom
  migrations plus its changed `ORDER` entry. Existing Gallery migration source
  files are not replaced. Custom additions are listed below.
- Existing `asset`/`library` table definitions are not changed. Asset IDs, owner
  IDs, library IDs, capture metadata and media paths retain their upstream formats.
- OpenAPI preserves all 371 official operations and adds 28. The existing three
  timeline GET operations gain optional parameters; this is an extension, not
  proof that every client workflow is compatible.
- Eight pre-existing component definitions differ: `AssetOrderBy`,
  `AssetResponseDto`, `MemoryUpdateDto`, `ServerFeaturesDto`, `StackCreateDto`,
  `SyncAssetV1`, `SyncAssetV2`, `TimeBucketAssetResponseDto`. Compatibility tests
  must validate old required members/types and request defaults rather than
  requiring byte-for-byte equality of an intentionally extended spec.
- `AssetBulkDeleteDto`, `TrashResponseDto` and `SyncRequestType` are unchanged.
  Runtime behavior of force deletion, Trash filtering and scanners does change
  and therefore requires explicit behavioral tests with old clients.
- Authentication/user/sharing/person/ML service files are unchanged against
  official 5.7.1. That reduces the changed surface; it is not a runtime PASS.
- Flutter Drift moves from schema 38 to 39 with `isIndexTombstone`; existing
  installation upgrade must execute the migration without replacing app identity
  or clearing data.

The custom server migrations inherited before Build 11 are:

1. `1791070000000-AddStackSuppression.ts`
2. `1791071000000-AddMemoryCandidates.ts`
3. `1793400000000-FixMemoryCandidateSchema.ts`
4. `1793600000000-AddAuthorizedAssetDeletion.ts`
5. `1793700000000-BindDeletionRecovery.ts`

The two deletion migrations deliberately reject `down()` to avoid discarding
suppression and recovery receipts. `scripts/revert-to-immich.sql` also refuses when
`asset_deletion_tombstone` exists. Thus the README's unqualified one-command switch
back to stock Immich is **not applicable to this HP fork**. A rollback must use a
reviewed Gallery image that understands the persisted tombstones, triggers and
queued-job contracts; reverting the image alone to stock Noodle 5.7.1 is not a
supported safety strategy. This exception must remain explicit until a separately
tested upstream conversion preserves those semantics.

The 291 external `active + deletedAt + isOffline` records remain offline index
tombstones, not user Trash. No compatibility procedure may convert or delete them
by inference. Synthetic regression fixtures cover this distinction; production
records remain untouched.

## Official 5.8.0 changes not integrated

Build 11's inherited base is official 5.7.1. Official 5.8.0 is based on a rebased
Immich 3.3.1 history: the merge base with our current history falls back to
`ca4637adc7959029176003553a4f183f45810d09`. The graph reports 1,834 upstream-only
and 1,671 fork-only commits; those are **not** counts of unique missing patches
because upstream replayed its existing Gallery changes. The content comparison
is the relevant starting point: 1,538 files differ at the pinned Build 10 source.
Do not blindly cherry-pick this graph or claim all those commits are new features.

The official 5.7.1 → 5.8.0 source delta includes four upstream migrations:

- `1789419229196-ConvertUserOAuthIdEmptyStringToNull.ts`
- `1790587508209-RenameGeoNamesCountries.ts`
- `1790616293884-PersonSharing.ts`
- `1790693088454-AddPersonUserTableSharedBySharedWithConstraint.ts`

It also includes four new official Gallery migrations:

- `1794000000000-AddAssetFavoriteTables.ts`
- `1794100000000-DropAssetIsFavoriteColumn.ts`
- `1796000000000-AddAssetFaceCreatedBy.ts`
- `1797000000000-AddAssetLocalDateTimeIndex.ts`

Notable integration work includes per-user favorites (the old `asset.isFavorite`
column is removed), MemoriesV2/AssetFacesV3 sync and capability negotiation,
upstream person-sharing dormant compatibility, ESM build conventions, Bitmap
thumbnail APIs, ML loading/inference, album editor/leave behaviors and mobile
background upload fixes. Official release notes explicitly warn about the
favorites migration and GeoNames re-import load. These are meaningful schema,
protocol and worker changes; a release tag alone does not prove an HP upgrade is
safe.

**Integration decision:** 5.7.1 is the verified existing upstream baseline.
5.8.0 is the latest stable target, but safe incorporation has not been demonstrated
by the provenance audit. Any Build 11 that does not actually port and validate
that delta must state “Noodle 5.7.1-compatible base; 5.8.0 upgrade pending”, and must
not claim full latest-upstream compatibility. Avoid history rewriting or silently
mixing two SDK/schema generations. Preserve all existing branches and use a
normal reviewed integration branch with explicit migration/rollback evidence.

## Reproducible checks and release gates

Read-only provenance commands (no production access):

```bash
git fetch --no-tags --recurse-submodules=no https://github.com/open-noodle/gallery.git \
  refs/tags/v5.7.1:refs/remotes/noodle-verified/v5.7.1 \
  refs/tags/v5.8.0:refs/remotes/noodle-verified/v5.8.0

git merge-base 3d60f90461511659812eb1341ecda394ba9e1571 \
  da5480ae42b77db9cae729f2447ec9b3079ba4a7
git diff --exit-code da5480ae42b77db9cae729f2447ec9b3079ba4a7 \
  3d60f90461511659812eb1341ecda394ba9e1571 -- server/src/schema/migrations
git log --reverse --format='%H %s' \
  da5480ae42b77db9cae729f2447ec9b3079ba4a7..HEAD
```

Use the existing upstream suites (`server` Vitest unit/medium, web Vitest,
`e2e` API/integration and Playwright, Flutter tests/codegen/analyze) and the Build 11
compatibility gates. Runtime database validation must use an isolated disposable
restored copy, never production. A previous PG restore PASS from Build 10 proves
that backup could be restored then; it does not prove this new application/schema
upgrade passed or that a newer backup is restorable.

| Compatibility area                                | Provenance audit result                               | Remaining release evidence                                        |
| ------------------------------------------------- | ----------------------------------------------------- | ----------------------------------------------------------------- |
| Official 5.7.1 ancestry and migrations            | PASS, exact commit/tree comparison                    | Final Build 11 gate                                               |
| Existing API surface/IDs                          | PASS for static preservation; runtime NOT TESTED here | Generated SDK and old-client API tests                            |
| Authentication, sharing, ownership                | Changed-file review only; runtime NOT TESTED here     | Upstream auth/sharing and multi-owner tests                       |
| Existing production database upgrade              | NOT TESTED here                                       | Isolated current backup restore → upgrade → metadata/count checks |
| Managed/external synthetic media and rescans      | NOT TESTED by provenance audit                        | Filesystem/PostgreSQL/queue integration suite                     |
| Android/iOS installation identity and OS deletion | NOT TESTED on devices                                 | Signed update and platform permission acceptance                  |
| Live Photos cold timeline/browser                 | NOT TESTED by provenance audit                        | Browser regression plus physical devices                          |
| Thumbnails/transcoding/ML/Memories/jobs           | NOT TESTED by provenance audit                        | Existing worker suites and uploaded disposable-media smoke        |
| Preserving 21 paused jobs/reconciling six         | Production outcome unknown                            | Existing sealed receipt reconciliation, no unsafe replay          |
| Image-only deploy/rollback                        | Existing tooling preserved                            | Exact-image isolated/HP preflight and rollback receipt            |
| Latest Noodle 5.8.0 integration                   | NOT INTEGRATED at starting commit                     | Full schema/protocol/build integration and upgraded-DB tests      |

Do not relabel any NOT TESTED row PASS based on a count of unit tests. The final
release test report records which suites actually executed, their exact counts,
and physical/operator gates. Production deployment remains separately authorized.

## Complete inherited fork commit manifest

- `22caae3ff3146490fb3e6fe0c6861b5c985edb36` — mobile: add pinch zoom to memory photos
- `4f9b24746888940826ba9c2801cef6d9a116867e` — mobile: show asset count on stack thumbnails
- `484a443d4632d972042d2309844871fc4e40e167` — mobile: add manual stack management
- `f183e67d05c5ca0f4591801756a4d881304cc74b` — server: persist manual stack suppression
- `a3dd4093488ce57aca7af5278e51586c3ed61fd0` — mobile: rename app display name to Фото
- `2406b60c5bd37b1ceea003a2da46295dc8c7de31` — mobile: improve system photo integration
- `d738cd28d56c12129f3bd4983731303219fa05c9` — memories: support generated titles and descriptions
- `e0c274055ddd783ff3c70fa23c95d768e7fd4b8b` — memories: add persistent candidate memory workflow
- `0e0790b9fa5f9804062076dc39475765946a1586` — fix: complete mobile validation and owner-scoped stacks
- `ec3dbe57c3ec1e27053655b209ad282358e80b6f` — fix: align memory candidate database schema
- `00c3261578a34b01dabe1c7c070926fdc48f484d` — feat(mobile): autoplay live photos in timeline
- `07f7a8a8e98a52ba7bcd70a30c3b8018a00775c0` — fix(mobile): require a new viewport for live photo autoplay
- `8e8be7e47b2151f690c5b90cf09f7f2b9927cae4` — feat(mobile): fill main timeline rows with adaptive photo tiles
- `0e376fdf5aa398df7914a35e90fca4d7ddcf3f0f` — fix(server): stamp custom builds with Gallery release metadata
- `2bbad07f2bfb475fe1064953baaadde09c6d6276` — feat(mobile): localize Photos product branding
- `0f89d8ad2d4b8128e8734bd1f3cf1711ccab8412` — feat(mobile): share and save server-only originals safely
- `5928803825f85c1807f71d8c9e40a9b65a6329b1` — docs: finalize server-only originals validation report
- `7dd47c463f996d210d53b817aa95d16e757af729` — feat: add private AI Magic Eraser with safe photo copies
- `30b2d01b41489dd8dfcd2470d65a369290b94ecb` — docs: add Codex task for Memories VAAPI optimization
- `58027759277f995032d37adfd0feccbfaf18c75e` — feat(memories): let users hide and delete memories safely
- `2d4c269c76d7d2f1dfa7686f204321f64d6bd8a8` — Merge origin/work to preserve parallel task documentation
- `fe18abe3a4cbd9a14fea675445fd50fe8d2fabd9` — feat(memories): expose owner lifecycle and rejection snapshots
- `6a4c8dcda33d9c188fbf696b533d79e0cf2e4ae3` — docs(ios): assess free distribution and refresh limits
- `171a1f5be28d7d93c1aa4c5b276c4bba27787475` — docs(stacks): record HP automation policy and verify compatibility
- `8847de5df41f611775bbc25cd5620bffe2fdab9f` — fix(mobile): preserve faces in timeline thumbnails
- `1b0e0fb47357d238df2620b90056935ed50d6edc` — fix(trash): group mobile and web timelines by deletion date
- `11e80b93a0ef609ad2d5b52a086033cfce31e712` — feat(tools): prepare owner-scoped Takeout album dry-runs
- `1077df262d632e08905ff1c465423f3ddfe5e455` — fix(tools): match repaired Takeout media with independent evidence
- `a1ab0826ab266ea6ad09f19ab9288805b606eab2` — fix(mobile): keep live photo timeline previews sharp and aligned
- `7b39a7f73b3de28ae80bddd5e51be94c70c11f6d` — fix(mobile): restore motion timeline autoplay for camera pairs
- `60adb07b8c8d1e55763fa83258d5e5865069cffe` — fix(ios): drain background work and preserve live photo transfers
- `9034f4027d1eadbd4c5ac19ad668c9f173f7a96c` — ci(ios): verify unsigned archives without release credentials
- `5d793d432465f042220c39f3f6b838ab607f192c` — docs(ios): record Actions gate and final shared build preparation
- `3ab21aaab429eab289c6170c852a2860d15a76b9` — ci(ios): regenerate CocoaPods lock with frozen verification
- `30db45c25f717c53335c22b2b32665e4e1ff0fd4` — fix(ios): synchronize CocoaPods lock with Flutter plugins
- `362c23b7bb3a89d87cf69d4fcefa567c8447e3e8` — fix(ios): deduplicate shared CocoaPods framework targets
- `08c646e9c204ac62cddace21360503ff3af46b09` — fix(ios): synchronize CocoaPods lock with Flutter plugins
- `1f2faaeb556c02e3df562e4f09a9fb0d21f7cc45` — fix(ios): verify fresh Flutter product archives
- `be1bec04a73a9f949a6297996298f1ca647a5292` — feat(mobile): customize Library cards and add Live Photo collection
- `f0fefc352ba1c3a01d0a2d0b4954d020c334eb95` — fix(ios): propagate Flutter versions and verify unsigned IPA artifacts
- `7f04b242b4d365fbbd386aa33df7b7122535bb19` — fix(server): preserve concurrent user trash during library rescan
- `878464de08d00aa36bd5405fc16c485bbb298735` — fix(mobile): retain verified asset identity through Android trash refresh
- `9f5724e6bfa7ce6b3c6af6e3af865ff7d7e71317` — docs(mobile): record trash validation and HP free iOS pilot steps
- `fff90e5dc4ce2d4ae1d2aa80994042156eee51a0` — ci(ios): retain native Xcode diagnostics in unsigned builds
- `9b235225f4b2c243a0173917ebe0a2e13c4ed832` — docs(android): design reversible Shizuku cloud picker activation
- `159761d88c05e70101fb601f3f0efd7219e761ef` — fix(ios): use latin display name for share extension signing
- `75633fc0d0071c18d9e48ce1017e830d8556416d` — fix(ios): localize launcher name without Cyrillic App ID registration
- `30c6468d431fa144cfde63bed7e33f4f936f640a` — feat(android): add opt-in cloud media provider with reversible Shizuku admission
- `4f0dbca11980ec743047a7e256ba1ea6a0c80b9d` — test(mobile): exercise native timeline motion and trace runtime stages
- `bcf9862aab1e6d400d440d48ea2a119cf1ca2ecf` — ci(android): verify media pilot on emulator and retain validation APK
- `12ec82d56f94cb7515b000cef0d7fde5776c01cd` — docs: record external Memories and VAAPI source boundary
- `c9f1485db7f644c51340445ae22f43ccac6d8c1d` — fix(android): allow pending Shizuku recovery after permission revocation
- `1529fa6599e089832ce6df257373909e43c10990` — ci(android): install supported SDK packages for media verification
- `df780a0704156f62994248b1949ce0b090fb12ca` — fix(android): validate and preserve exact cloud admission override state
- `09fc1052465261ee8e0f921c8a0f0647cf7e9899` — ci(android): prepare pinned Flutter wrapper before native unit tests
- `23ba669255020414846817e00dda8010c7359088` — docs: identify existing ordinary video embedding path for Memories audit
- `9691508fe32e725c5d773faf3714b3b882f1cc62` — fix(android): include current collection ID in cloud media notifications
- `56ed1fec095240fc04f50e763fbcba39656ae8d3` — fix(android): serialize account-scoped cloud collection version publication
- `a3eed5f95e68f7824432c5a9cd33cb2c4f0278f3` — fix(android): initialize scoped generation for an existing cloud snapshot
- `329c8b08e7e213e4f53379f90679d96ad6c3815b` — test(android): align MockWebServer with existing OkHttp graph and expose JUnit causes
- `caf35d659788f8bb204e84855c5dab94a2f9a67c` — ci(android): expose unchanged native playback failure in check annotations
- `337f1430744bc7b30c801202188ad98becca6a69` — fix(android): close cloud preview setup and request cancellation races
- `c7f7c44c7d486ed4e6d589c2b1f8daa8637f6661` — fix(mobile): keep Library album preview reactive during sync
- `36840b87523dfb302688bb08371eae385937cc1f` — chore(mobile): advance verified media handoff to build 6
- `5b5a039f1a40b26483404a9d9b9befbd488b68e8` — build(mobile): add reproducible Android and free iOS release handoff tooling
- `176008c753d24a28299e8910330776f8b30f049b` — fix(mobile): preserve Trash across stale sync and cache resets
- `752d90a174e6c3988638e897b257bf321f744670` — test(android): retain native motion stage evidence on failure
- `e64f838d5b0d2efed64b89be9f12278043b5d4a3` — test(android): restrict playback diagnostics to anonymous stages
- `56dc72218be14ad2059b134b4c4d5a4f019608d7` — build(mobile): align v38 snapshot discovery order without schema changes
- `04f2e1ecf6ccb8b460383ee8a3fd37bfafc50748` — fix(android): paint timeline surface during native decoder preparation
- `17fc9ede3b934b76617e3c03f70109ff33d6d38b` — fix(build): regenerate release plugin registration after native tests
- `ab0d0205c30b313b97bbcf64641bb073de864dd5` — fix(release): reuse verified unsigned iOS handoff on retry
- `102559e9d887c1defdb1d9037b0b691fb3d75371` — docs(testing): preserve media validation and release evidence
- `6b94461a394d4fea346b31118c3e1412317f7c76` — docs(release): record verified Android and unsigned iOS artifacts
- `c950e5aa48bf05d5d6eb936286613e0df02f2afa` — fix(mobile): converge optimistic Trash restore
- `2c4e3f8cce6c33b6eea98064cfc74d9003303d09` — merge: include remote work checkpoint
- `608c34a963262d88481e6f8fef345fee47bf498c` — fix(mobile): narrow maplibre import for Trash error handling
- `6e439a7294dbda94331d8b06fc5373658bdc984c` — fix(mobile): guard Trash and Restore operation lifecycles
- `5e6fa74fe22a06eaa1ebf1ff7c5c8f0e904ddf63` — feat(gallery): improve cloud admission, albums, trash and release validation
- `7531c1585ca9359ff50316ed66e2f8183f9a0043` — Merge reviewed CLI changes with Trash/Restore P1 fixes
- `2348266a64047ae67a43b7020517c9c187ee1eac` — fix(android): recover interrupted cloud admission safely
- `8e4ac63fd1f11e80bec9b4b3e374797656a518c4` — fix(release): validate SDK 36 binary provider manifest
- `42790b06edc21438811e56e40c431eee37c24894` — test(gallery): verify Trash lifecycle in native picker projection
- `372bffbebcf0f86a7bde5576e1421ce827596c31` — fix(trash): revalidate expiry and acknowledge actual restores
- `1deb5cbed4c1cc901dee900e7c2f097ba8107b24` — fix(mobile): reconcile cached Photos search with Trash state
- `1d773fd6fad785414b3f7bdc1f7484a1b5bf4e7d` — docs(audit): record CMP and NAS boundaries with read-only HP diagnostics
- `6e547a94a437d32f40cc7ca860255fd9b8f285be` — fix(trash): guard legacy deletion jobs and irreversible claims
- `d74db37930d23fe0535dc5c58d6ab4e18aa49f01` — fix(mobile): reconcile folder viewer with durable trash state
- `da8dee6f085a790561712816738c4caa1df4ffd1` — docs(trash): record validation and retention queue safety gates
- `5cae22ebab3cf3cbb660352d4f9a07774f15dbe7` — chore(release): prepare guarded trash backend and mobile build 8
- `6a558b554e26e8c0fc5bc5c99259a92e7ef26a56` — fix(release): preserve source iOS build metadata and isolate artifact runs
- `b2de615eaf59c6fd8e6bed5afa4cd2fe0566814d` — fix(release): distinguish guarded jobs and locate legacy backups safely
- `020524a90a577f0ed2ed733b8c1bc2743e82b754` — fix(release): validate version DTO and pin approved artifact source
- `0ca5ff7ebdc56140cdc484276e6fcd02086b4b5e` — fix(ci): preserve sanitized Docker fixture failures and owned cleanup
- `5dfcdf182144e10aeaed7f4da620350ac783c75a` — fix(ci): authenticate read-only GHCR fixture pulls
- `d3f999e7d21c7c7f4e9b9bc5ac1e1af62de6cf3d` — fix(diagnostics): complete read-only Trash release inventory
- `565ef38c0c39f3ee896f5afd055d4d57a676d503` — chore(release): gate Trash deployment on recovery and preserve built mobile artifacts
- `1a4fa939604bbdb7f6bfb2abbeb944209a36a69f` — tooling: publish pinned NAS recovery validator [skip ci]
- `4f1d22607a735043842f36f3f8b3a28e44cbd587` — fix(tooling): handle stacked autofs mounts in NAS recovery validation [skip ci]
- `0e0ed0434f985c01d4f74eacaf326753211ec650` — feat(tooling): gate Trash release on a fresh isolated backup restore
- `65d6cbb6c521826f3c643a1888ca2f46d108a1d4` — fix(tooling): verify digest-pinned HP PostgreSQL image identity
- `4b8bdd4430af3b66631e946e87b954ce08eb1366` — fix(tooling): prove frozen image content across Docker stores [skip ci]
- `f1e274720eb73146936a35ac1f2d5122f9fc3ae7` — ci: allow isolated frozen artifact proof on tooling branch
- `3f00f1730ecce5213ac7d8455664589a8b11c531` — ci: expose bounded frozen artifact verification error
- `da4a47d0c6350b96364ee0844add553592331a4f` — feat: complete authorized Trash and permanent deletion lifecycle (build 9)
- `242337b24fa32a800a7d99b1bacbb4f65b01d091` — ci: identify sanitized permanent-deletion smoke rejection
- `a33fce0093905c4e1df2399e444f3bc03573dca4` — fix: complete required deletion outcome translations
- `53a9dc847ae3a5c2340f85c7540c08f41cb1b21d` — ci: expect ownership rejection when restoring a removed fixture
- `f45bf9a811c64685d40faa82a7fd35d9b94252c4` — release: seal build 9 artifacts and guard additive upgrade and rollback
- `76bbcf708e12ee811041adcc38fd7909a7d6da15` — fix: exclude offline index tombstones from user Trash and accept absent derivative slots
- `b0963403caa3a5a2df79c93fe461a058548a6d14` — docs: pin build 9 operator handoff to verified Trash correction
- `3c7ce5cab2e75c89d16110578c54964ea14b6061` — release: exclude obsolete build 8 execution wrapper from build 9 handoff
- `968492c09641c49f34edbcea7367fc197ef3c531` — fix: separate offline index state from durable mobile Trash across cache upgrades
- `22b3633eb917b529d49e84465fc020ef5c3bf2fd` — docs: bind build 9 handoff to verified index-state migration
- `6d9dae77eaa46e99681f39c69e90a8a05c85324a` — docs: record final-source validation and existing HP Docker access handoff
- `e6ab95e695f085c3016072ebff44d4ba02695cb5` — fix: preserve verified offline index state when reconciling uncertain Trash
- `a895fd79fd74c8714213939434b1e8f7b157ffa5` — fix(assets): add explicit managed deletion consent and scope preflight
- `77404b9e9bcbeda9f4e9627981437c03a892f920` — feat(trash): expose managed consent and explain scope authorization
- `dcc78926fbd89ffcf1a8f8ccc4702859a135166b` — docs(trash): record offline semantics, authorization and worker-safe rollout
- `19452ecfad7b39c921829f952ebd0f268e8dcc6a` — fix(deletion): verify recovery grants and anchor original removal
- `8a0dd25fc11c13e89bf5fecc5c8a2b8fb92262d7` — fix(clients): explain verified deletion consent and prepare build 10
- `cceb5733d2b63b5812a5e5d9bd3682d61dc5132b` — fix(release): preserve workers and require hardened rollback
- `7c254414c816ac0d9f02703c1fb0902b9b97d8b7` — fix(release): preserve pinned historical migration identity
- `8f6253113568e8b0fd1535b8d8496be2d193094d` — feat(deletion): add verified external library owner consent and safe retries
- `7ef9c69123ba659f966e35c2f8eca7ff4893c18e` — fix(deletion): rehash resumed originals after directory durability checks
- `05191446144b4268be87c4f568a652c1f3ce011c` — fix(mobile): start live photo autoplay without viewer warmup
- `3ad43272e2452a90598631c874b31abcbe4191b0` — fix(server): secure new quarantine permissions on Synology NFS
- `95ae75790463a277b4ebe5d679c5b212c997b46a` — fix(server): persist mapped NFS quarantine identity before deletion
- `e71c39bb416167e8eb40a306f9a04d0efcdcb8d5` — fix(tooling): bind Synology recovery exports to owner-scoped evidence
- `b3034e6f78ab908cf98bed159a640c8e333e29b0` — fix(tooling): compare recovery Docker mounts without order dependence
- `95ee6906cb360279de9e56428b90ff529d39ea2c` — fix(tooling): verify private backup copies against restore receipts
- `ea51a8acdc6f18ab5917c19b6f3833d740b4e9ba` — fix(server): allow admin preparation for owner-scoped deletion
- `82ac677ffd207f23a8bee014d5b2937d77f22aaa` — fix(release): hash resolved Compose environment for image updates
- `4ab426a252656cbd2154cf3a903c0ea957f02183` — fix(release): prepare pinned hardened rollback without guessing old source
- `31a8aecf7afd008714ce1240e80d7fb8f550f81a` — fix(release): verify confirmed file jobs before acknowledgement and image update
- `5c9086889d0c4f2f54d374f64ae05cc22fecbad7` — fix(release): admit verified owner upload cleanup jobs without granting original deletion
- `f4959f53ac15edbb09e5c9259ec9b246cd9fa0f9` — fix(release): validate Docker capability aliases and recover early scoped helper stop
- `3d60f90461511659812eb1341ecda394ba9e1571` — fix(release): diagnose interrupted helper commands without exposing private output
