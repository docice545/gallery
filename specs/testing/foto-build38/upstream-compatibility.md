# FOTO Build 38 and Gallery 5.10 compatibility

Reviewed 2026-11-05 against the published Gallery tag `v5.10.0`, commit `0c5bff615d45a040a4cb827212ed23cf76d265bc`, released 2026-11-04. [Release notes](https://github.com/open-noodle/gallery/releases/tag/v5.10.0) describe Spatial Scene, Library Cleanup, mobile search/motion, S3 database backups, space member permissions and fixes for shared stacks/people. These are upstream descriptions, not claims that FOTO implements or has tested them.

FOTO's mobile source is **5.7.3+38**. Its server source package is **Immich 3.2.0**; the existing branded server build reports **Gallery 5.7.3**. The upstream tag's server source package is **Immich 3.3.5**, and its mobile source placeholder is `1.0.0+1` (release tooling injects the released app version). Those source/package, app/build and branded runtime version numbers are distinct. Flutter is pinned to **3.47.2** in both trees. No version string or build number was changed to imitate an upgrade.

The existing structural checker was actually run against the fetched immutable tag. It inspected 400 upstream operations and reported **FAIL: 160 contract findings**, 17 changed existing operations and 49 changed schemas. Seven migration paths differ, including the ordering file. “Removed” in this directional report means that an upstream 5.10 contract is absent from the older FOTO candidate; it does not mean this UI branch deleted that contract. This conservative report is an upgrade blocker, not a report of 160 newly introduced FOTO defects. It cannot certify runtime or database compatibility.

| Area | Finding and consequence | Required separate upgrade checks |
| --- | --- | --- |
| App/backend versions | Current FOTO and upstream use different core and branded versions; same Flutter SDK alone proves no wire compatibility. | Pin server image and both mobile artifacts independently; exercise authentication and feature negotiation in mixed-version pairs. |
| API and generated clients | New cleanup, adjustment/trim/depth, search-options and people-user endpoints are absent from FOTO. People requests, sync entities, asset responses and permissions differ. | Regenerate OpenAPI/SDKs from the selected server; review every changed request/response and preserve older-client fallbacks. |
| Database | Upstream migration bodies and ordering differ; new OAuth, geonames, people-sharing and face-state migrations are present. | Restore a verified HP backup into an isolated database, inspect recorded migration names, run candidate migrations, verify data/owner invariants, and test recovery. Keep the existing duration-migration compatibility alias. |
| Deletion and external storage | FOTO adds owner consent, durable irreversible receipts, root identities, physical-file verification, reimport suppression and partial-result handling. | Preserve these controls in every upstream deletion/cleanup route; run managed/external/Live Photo matrices with actual filesystem failures. Upstream Library Cleanup is separate from FOTO's device-copy cleanup. |
| Live/Motion Photo and stacks | Shared-stack and motion changes overlap with FOTO's preserved native Stack API and external HP maintenance process. | Recheck paired originals, local/server playback, backup, editor copy and deletion; retain asset-preserving Stack DELETE, manual suppression, owner boundaries and Anna's existing automatic-stack exclusion. Do not introduce another auto-stack worker. |
| Offline catalog and timeline | Search/sync/memory changes can invalidate cache identities, dates, prefix layout and owner-scoped local data. | Repeat FOTO cold-offline, reconnect, immediate year scroll, cache persistence, duplicate-memory and scroll-anchor regressions on the upgraded client. |
| Editor and AI eraser | Upstream adjustment/trim/depth APIs are different from FOTO's current editor/export and inpainting path. | Preserve image coordinates, history, full viewport, real model inference and save-copy ownership; explicitly migrate drafts if necessary. |
| iOS/Android | Upstream release artifacts do not contain this branch's FOTO fixes or establish SideStore signing compatibility. | Build the selected SHA with native toolchains, inspect entitlements/plugins/signatures, upgrade the existing Android installation and install a provisioned IPA through SideStore. |
| S3, backup and deployment | Upstream adds S3 database backup behavior. No production storage or timers were changed here. | Verify backup and restore on isolated HP storage, preserve existing mount/cache/model paths, and prepare an explicitly reviewed deployment/rollback procedure. |

## Separate migration stage

1. Freeze accepted FOTO artifacts and source SHA; record the HP database migration ledger and verified restore evidence. No production migration is implied by this document.
2. Create a separate upgrade branch/PR. Review the pinned upstream changes in small groups, preserving FOTO deletion, offline, editor, pairing and stack contracts. Do not mix the upgrade into the Build 38 UI fixes.
3. Reconcile schema ordering and aliases against the restored database. Run upgrades in isolation, verify owner/media/link counts and file hashes, and prove recovery from that exact candidate. An older image alone is not a sufficient rollback plan after schema changes.
4. Rebuild generated clients and test current/upgraded client-server combinations, real Docker jobs and original-file endpoints. Resolve every structural finding or document an explicit version-gated compatibility decision.
5. Build and test signed Android and provisioned iOS artifacts; complete Samsung, SideStore, backup/sync and Live Photo acceptance. Only then decide release versions/build numbers and production deployment in that separate stage.

Reproduce the structural check after fetching the tag into a review ref:

```sh
git fetch --no-tags https://github.com/open-noodle/gallery.git refs/tags/v5.10.0:refs/remotes/foto-review/upstream-v5.10.0
python3 scripts/release/upstream_compatibility.py \
  --upstream-base 0c5bff615d45a040a4cb827212ed23cf76d265bc \
  --report /tmp/foto-upstream-5.10.json
```

Expected current result: nonzero exit and `FAIL`. The checked report is adjacent. HP restored-database compatibility and physical Android/iOS interoperability remain **HP_REQUIRED / DEVICE_REQUIRED**, not PASS.
