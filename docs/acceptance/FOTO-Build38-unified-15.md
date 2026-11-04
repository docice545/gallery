# FOTO Build 38: unified acceptance

Base: `d94389c98d2ac8cbdfe3e5bcf18b3bdaac23665b` from
`checkpoint/foto-build38-before-unified-fixes`. The checkpoint commit changes 43 files;
it is not a 43-file repository. Work is isolated in `codex/foto-build38-unified-15`.

Status: **IN_PROGRESS**. No HP access, signing, device installation or production rollout
has occurred. HP/Samsung evidence is mandatory before release, especially Live/Motion Photo.

## Architecture and baseline

Flutter 3.47.2 / Dart 3.13.2 (official tag `d3b14c8769`); mobile remains 5.7.3+38,
package `de.opennoodle.gallery`. Node/pnpm monorepo, NestJS backend, Drift local index,
Riverpod state, generated Dart OpenAPI client. `server/package.json` says 3.2.0;
this source package version does **not** establish the deployed server version.

Baseline backend: 505 tests PASS across `asset.service`, `metadata.service`,
`memory.service`. Build `@immich/sdk` then `@immich/plugin-sdk` before those tests;
without these generated outputs Vitest cannot resolve the plugin SDK. Mobile baseline pending.

Data path: server photo `livePhotoVideoId` references the hidden motion video;
Samsung embedded motion uses the existing extraction pipeline, Apple pairs use the
existing owner/library-scoped matching. Mobile playback, share and download retain
those links. Editing creates a static copy and leaves the original pair untouched.
Deletion stays in `DeleteAction` / asset service with selection/session leases,
server acknowledgement, restore queue and OS-confirmed local removal. The visual
coordinator only captures bounded painted thumbnails; it never mutates assets.
External auto-stack, production services and completed Takeout migrations are out of scope.

## Requirement matrix

| Item             | Main implementation / evidence                 | Acceptance                                                     |
| ---------------- | ---------------------------------------------- | -------------------------------------------------------------- |
| 01 toolbar       | timeline, compact_selection_toolbar            | one capsule; loading/empty; IME/gesture; stable scroll         |
| 02 album swipe   | album_trash_reveal                             | whole row moves; explicit confirmed deletion only              |
| 03 shared delete | delete.action, ghost_trap, fixed/segment.model | timeline/viewer/multiple/offscreen; no duplicate service calls |
| 04 motion        | ghost_trap                                     | bounded thumbnail; capture/flight/bin; reduced motion; cleanup |
| 05 notification  | toast service, delete action                   | compact localized receipt; real restore; errors separate       |
| 06 colors        | viewer surface, scrubber, selection status     | semantic surfaces/accent/foreground                            |
| 07 themes        | existing theme/config providers                | system change in place; contrast; no viewport shift            |
| 08 memories      | memory.service, memory provider                | up to 16 unique cards; no asset-count change                   |
| 09 singleton     | fixed/row_layout                               | bounded portrait/landscape/panorama in both modes              |
| 10 appearance    | semantic surfaces, editor dock                 | live persisted theme/preset/background; editor geometry        |
| 11 Git           | isolated branch, small commits, PR             | checkpoint ancestry and no secrets/artifacts                   |
| 12 upstream      | compatibility matrix below                     | separate migration; no version/schema disguise                 |
| 13 haptics       | existing setting/provider, action entry points | on/off; one short feedback per action; Samsung pending         |
| 14 cleanup       | cleanup provider/service/settings              | online verified backup; preview count/bytes; confirmation      |
| 15 grids         | Timeline / fixed renderer                      | recent/system/user album parity; 2594 mixed assets; anchors    |

## Upstream compatibility

`open-noodle/gallery` release `v5.10.0`, published 2026-11-04, states that it is
based on Immich 3.3.5. The release adds Spatial Scene, Library Cleanup, a search
redesign, motion, S3 database backups and changes to Space permissions. These are
not a cosmetic mobile version bump.

| Layer               | Checkpoint                                      | 5.10.0 implication                 | Decision                                                 |
| ------------------- | ----------------------------------------------- | ---------------------------------- | -------------------------------------------------------- |
| Android identity    | 5.7.3+38, original package/key                  | official APK signing may differ    | preserve existing key; no official APK substitution      |
| Data/API            | fork deletion, stacks, memories, Live Photo     | new cleanup/search/Space contracts | separate contract/schema diff and staging tests required |
| Flutter UI          | FOTO fixed editor, mosaic, local-first features | upstream search/motion may overlap | selective port only after regression review              |
| Backend             | actual HP version unobserved                    | upstream Immich 3.3.5 baseline     | no mass merge or production migration                    |
| SDK/CLI/Web/plugins | matching checkpoint APIs                        | generated clients can change       | pin together in a separate migration PR                  |

Migration gate: inventory actual HP image/version read-only; compare tag API/schema
and FOTO patches; test upgrade/rollback on a disposable database copy with synthetic
media; validate mobile plus Web/SDK/CLI/plugins and Live Photo; only then propose a
separate migration PR. Production rollout always needs a separate owner decision.
