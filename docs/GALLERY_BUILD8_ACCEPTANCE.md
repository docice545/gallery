# Gallery 5.7.2 (8): acceptance and release blockers

Frozen source: `6a558b554e26e8c0fc5bc5c99259a92e7ef26a56`.
Server 5.7.1; Android/iOS 5.7.2 (8). Tooling changes do not change these binaries.
**Verdict: BLOCKED for the expanded end-to-end deletion contract.** An artifact
integrity PASS is not physical acceptance or authorization to deploy.

## Confirmed scope mismatch

1. `mobile/lib/presentation/actions/delete.action.dart`, `_moveToTrash`, expressly
   preserves backed-up local originals. Only `localOnlyIds` enter device cleanup.
   This is contrary to the new requirement to remove the corresponding local
   copy when trashing a backed-up photo/video. Existing widget tests assert that
   preservation. The frozen APK/IPA must not be described as implementing the
   new behavior.
2. `_deletePermanently` ignores the returned cleanup count. OS refusal/partial
   cleanup is not reported per asset. The UI success message is server-oriented;
   it does not prove device deletion or physical server deletion completed.
3. `StorageService.handleDeleteFiles` catches unlink failures and returns Success.
   `AssetService.handleAssetDeletion` removes the row before queuing FileDelete.
   There is no durable per-file completion/authorization contract here that can
   satisfy recoverable, auditable permanent deletion under the new requirements.
4. External library cleanup intentionally preserves original bytes while removing
   the index. Soft Trash retains the row and survives ordinary rescans, but a
   permanent row removal is not a durable filesystem-identity rejection marker.
   If bytes remain following a failure, later import can rediscover them. There
   is no separately verified, per-library permanent-original-delete opt-in.

Completing these changes requires an explicitly identified new application
candidate, an approved authorization/tombstone policy, regression tests and
new affected artifacts. Do not substitute new requirements into the old release
manifest, change frozen checksums or activate retention as a workaround.

## Mandatory criteria

Statuses below apply to the **whole** criterion. Automated fixtures are separate
evidence, not a PASS for a device/production-dependent scenario. Never test
permanent deletion against family originals.

| #   | Criterion                                                                 | Status     | Automated evidence                                                                              | Exact remaining acceptance                                                                                                                                                                                                                          |
| --- | ------------------------------------------------------------------------- | ---------- | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Active photo/video visible until explicit Trash                           | NOT TESTED | Timeline predicates and local sync fixtures in the previously completed Flutter/PG suites       | Upload two disposable photos and a video; compare Android, iPhone and web before any action, after refresh and restart.                                                                                                                             |
| 2   | Trash removes active Timeline immediately on all clients                  | NOT TESTED | Trash pending/revision/sync tests; server visibility predicates                                 | On each client trash one disposable photo and video; confirm Timeline, search and album removal without refresh. On Android/iOS also inspect device Photos: frozen build preserves backed-up local copies and fails the new local-removal contract. |
| 3   | Trash metadata and retention correct                                      | NOT TESTED | `trash-timeline.service.spec.ts` deletion-time grouping/owner tests                             | Open Trash on all clients; verify original capture time, deletion day, current 30-day policy and video/Live identity. Do not edit production retention.                                                                                             |
| 4   | Restore chronology without duplicates                                     | NOT TESTED | PG chronological restoration and repeated Restore tests; Flutter pending revisions              | Restore the fixtures singly; check original date/time group, exactly one entry, original album membership, and unchanged bytes. Repeat after restart and delayed sync.                                                                              |
| 5   | Bulk Trash/Restore, including partial results                             | FAIL       | Server batch acknowledgements/revision protection tested; device cleanup result discarded in UI | New candidate must report actual per-asset device success/refusal. Test mixed photos/videos and deny one platform consent. Compare all clients after reconnect.                                                                                     |
| 6   | External originals safe during soft-delete/Restore/unauthorized retention | BLOCKED    | Isolated file and PG retention/legacy-job guards; production execution not performed            | Keep deletion workers gated. Use a separate disposable external library and compare streaming hashes before/after soft Trash, Restore and rescan. No family paths or queued real jobs.                                                              |
| 7   | Managed originals protected until authorized permanent delete             | BLOCKED    | Isolated managed-original lifecycle fixtures                                                    | Verify bytes while workers are gated, including expiration. Permanent operation requires a separate approved scope and disposable-only test.                                                                                                        |
| 8   | Cross-owner isolation                                                     | NOT TESTED | Owner-scoped API/Trash/Timeline fixtures                                                        | Two test owners: attempt access/delete/restore of the other's disposable IDs; expect denial and identical other-owner counts/hashes.                                                                                                                |
| 9   | Legacy FileDelete cannot execute unexpectedly                             | BLOCKED    | Atomic queue adapter + deployment API-only/pause gates                                          | Fresh approved predeploy check must report all seven states zero and no unresolved deletion hashes; after authorized deploy verify API-only workers and paused empty queue. Never clear/retry queues to pass.                                       |
| 10  | App/server restart and rescan preserve Trash and bytes                    | FAIL       | Pending/restart Flutter tests and stale retention concurrency fixtures cover soft Trash         | New durable post-permanent-deletion identity/failure protection is absent. In isolated fixtures test restart, file unlink failure, rescan and background backup without reimport.                                                                   |
| 11  | HP-signed Android build 8 updates build 7                                 | BLOCKED    | Frozen CI APK payload/integrity checked; CI certificate differs from HP certificate             | After separate signing approval verify `ad3e9c…ded18`, use `adb install -r Foto.apk`; do not uninstall. Verify login, local DB, albums, settings and build 8. Not signed or tested on S23 here.                                                     |
| 12  | SideStore update/extensions preserved                                     | NOT TESTED | Existing IPA/Runner/ShareExtension/Widget verification and ASCII/localization tests             | Re-sign using the existing Personal Team/SideStore mapping and LocalDevVPN. Keep App Extensions → Register App ID for Each Extension. Verify update without uninstall, session/data, Share Extension, App Group and Widget on supported iOS.        |
| 13  | Backup/albums/search/faces/viewer/video regressions absent                | NOT TESTED | Previously completed broad suites; frozen backend HTTP smoke                                    | On S23, iPhone and web exercise each feature using disposable photo, video, portrait and Live/Motion pairs; verify ordinary auto-backup does not resurrect rejected fixtures.                                                                       |
| 14  | PostgreSQL and NAS recovery possible                                      | BLOCKED    | Owner-supplied earlier PG/NAS PASS; fresh exact-backup restore tooling                          | Reuse unexpired genuine NAS receipt; create a new private SQL/gzip backup and restore that exact hash in isolation. Old PG receipt is insufficient for a new dump; do not refresh timestamps.                                                       |
| 15  | Deployment preserves unrelated HP services                                | NOT TESTED | Disposable Compose rollback/container-isolation test                                            | Only after separate approval: compare PostgreSQL/Redis/ML IDs; health-check Gallery. Do not run commands against VPN/DNS/proxy/routing or change Docker globally on HP.                                                                             |

## Current versus earlier validation

The application source is unchanged. The prior handoff records 4,564 Flutter
tests (1 skipped) and 627 PostgreSQL tests (12 skipped), including real row-lock
competition and synthetic original files. These are prior evidence, not a new
run and not proof of OS deletion, NFS ACL enforcement or physical installation.
New image identity/tooling tests and CI results are recorded separately in the
release handoff. No signed HP APK or device/production acceptance is claimed.

Original-file safety, owner isolation, Restore correctness, or rollback failures
are hard blockers. There is no permission to run production deletion, merge,
restart containers, sign, enable workers or retention in this document.
