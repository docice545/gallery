# Gallery build 9: release acceptance gates

Source: `968492c09641c49f34edbcea7367fc197ef3c531`. Backend 5.7.2, Android/iOS
5.7.2 (9). Automated evidence is distinct from physical/production acceptance.
No HP, NAS originals, production queues or signing keys were touched.

## Required criteria

| Criterion                                 | Automated evidence                                                                    | Required operator/device test                                                                           | Overall status                               |
| ----------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| 1. Active photo/video visible until Trash | Flutter visibility/Timeline tests; real PostgreSQL lifecycle                          | On each client confirm disposable still/video visible before Trash                                      | NOT TESTED on devices                        |
| 2. Immediate removal on Android/iOS/web   | Revision/tombstone/DeleteAction tests; web completed-ack pruning                      | Single/bulk Trash on all clients, navigate active views immediately                                     | NOT TESTED on devices                        |
| 3. Trash metadata and retention           | Backend HTTP Trash/Restore, original-byte preservation; manual-retention UI           | Compare dates/timezone/orientation and verify automatic deletion is disabled                            | NOT TESTED on devices                        |
| 4. Restore chronology without duplicates  | Real PG bulk restore/album links; Flutter stale/late revision tests                   | Restore across timezone/day boundaries; check exact timeline position and count                         | NOT TESTED on devices                        |
| 5. Single/bulk Trash/Restore              | Flutter API ordering/partial results; real PG bounded acknowledgements                | Select mixed still/video, cancel one OS prompt, retry only unresolved work                              | NOT TESTED on devices                        |
| 6. External NAS originals protected       | Default-deny/legacy retention/external index fixtures; disposable unlink tests        | Hash disposable NFS media before/after Trash, Restore and unauthorized permanent request                | BLOCKED pending approved disposable NFS test |
| 7. Managed originals protected            | Default-deny and explicit policy fixtures; HTTP permanent-deletion smoke              | Verify denied policy preserves bytes; authorize only disposable scope and verify selected unlink        | BLOCKED pending approved disposable NFS test |
| 8. User isolation                         | Real owner/path/content/journal and shared-root guard tests                           | Independent docice/Anna/Lenia disposable items, verify other users unchanged                            | NOT TESTED on devices                        |
| 9. Old FileDelete cannot run unexpectedly | FileDelete original-path denial + atomic queues/legacy inventory guards               | Fresh prepare/recheck; deploy API-only and verify queue remains paused                                  | BLOCKED pending HP approval/PASS             |
| 10. Restart/rescan anti-resurrection      | Durable local IDs/checksum/DB insert triggers; retained receipt tests                 | Restart app/server, offline reconnect, external-library rescan of disposable library; no ghost/reupload | NOT TESTED on devices/HP                     |
| 11. Android update identity               | CI APK manifest/package/version/native verification; HP certificate pinned            | HP-sign after approval; update installed S23 without uninstall, verify auth/settings                    | BLOCKED pending HP signing and S23 test      |
| 12. iOS SideStore/extensions              | Unsigned archive/base-name/version/extension checks; iOS tooling tests                | Same Team/mapping update; verify extensions/App Group/Live Photo/7-day refresh                          | BLOCKED pending physical iPhone              |
| 13. Other functions preserved             | Full Flutter run plus focused corrections, relevant backend/web tests                 | Backup, albums/search/faces, photo/video playback, local/cloud auth; no family deletion                 | NOT TESTED on devices                        |
| 14. DB/NAS recoverability                 | Historical operator PG/NAS PASS; new fresh-backup exact-restore/upgrade/rollback gate | Fresh prepare PASS; keep real snapshot provenance and same-file sample hashes                           | BLOCKED pending fresh HP prepare             |
| 15. Unrelated HP services untouched       | Deployment only targets server; unchanged container/config guards                     | Compare before/after Gallery, VPN/DNS/proxy/routing availability without changing them                  | BLOCKED pending approved deployment          |

No row above is a physical PASS based on source inspection. This is a buildable
candidate with explicit operator gates, not a claim of completed production acceptance.

## Automated results and limits

- Full Flutter: 4,575 passed, one skip, one old OS-restore expectation failed.
  That expectation was corrected to the required no-local-recreation contract;
  the corrected LocalSync/DeleteAction group passed 28 tests. New deletion API,
  durable suppression and backup cases passed 42 tests. Full analyze: no issues.
- Full backend units: 6,606 passed, four failures, one expected failure, 12 skips.
  Two new expectations were corrected; focused groups passed 296 and 423 tests.
  Two previously existing revert/scope-guard failures remain; full suite is not
  represented as PASS. Changed server TypeScript/build/ESLint passed.
  The same two guards were executed against the exact production baseline
  `42790b06edc21438811e56e40c431eee37c24894`: 33 passed, 2 failed. The candidate
  also produced 33 passed, the same 2 failures. The old revert list omits three
  historical migrations; the memory import is falsely counted as a query arm.
  Neither authorizes reverting the new durable deletion migration.
- Full PostgreSQL: 3,241 passed, 47 failures, 12 skips. Environment/fixture/timing
  failures and corrected new expectations are recorded separately; full suite is
  not represented as PASS. Final deletion/lifecycle group passed 17; authorization,
  real concurrency, schema and migration group passed 23. Migration down refuses
  evidence loss. Existing non-deletion failed suites are not claimed revalidated.
- Web deletion/viewer tests: 8 passed; added partial-ack regression group: 6 passed.
  Full web check has existing type/fixture failures; ESLint tscompat crashes.
  These are not hidden or counted as successful checks.
- iOS tooling: 108 passed. Runtime compilation/archive verification is established
  only by the exact successful build-9 CI artifact. No physical iPhone PASS.
- Final resumed PostgreSQL Trash/count/cover/retention regression group: 26 passed.
  Offline Active index tombstones are excluded from user Trash; a failed authorized
  deletion remains visible. Read-only audit/CI-harness group: 18 passed, including
  valid null derivative slots and rejection of malformed/relative paths.
- Final index-state fix: 894 focused Flutter/cache-migration checks passed,
  including all schema paths to 39; full analyze and formatting passed. Backend
  sync/Trash PostgreSQL group passed 31; DTO/sync/asset units passed 281; scoped
  TypeScript and ESLint passed. Replay verifies legacy markers against a current
  GET; pending/newer Trash remains protected. Real SQLite restart preserves index
  classification; rejected Trash restores that classification without a marker.
- Final-source full backend units: 6,609 passed, one expected failure and 12
  skips; the same two baseline revert/scope guards still failed. No new failure
  appeared after the asset response/sync correction; this is not a full-suite PASS.
- Release-tooling guard tests and real Docker/rollback proof results are recorded
  in the final handoff. No production backup restore or deployment is executed
  by cloud tests.

## Exact disposable acceptance procedure

1. Use a separate approved disposable library/album. Create unique non-sensitive
   portrait and landscape photo, video and Live/Motion pair for each user. Include
   local-only, NAS-only and backed-up-on-both items, and timestamps across a day/
   timezone boundary. Record counts, dates, pair IDs and streaming hashes privately.
2. Trash one photo and one video; then bulk mixed items. On Android/iOS accept the
   platform prompt. Repeat with denial and cancellation; UI must show actual local
   results while server Trash remains consistent. NAS bytes must remain unchanged.
3. Deny network before and during requests. Restart/reconnect with an empty sync;
   unresolved delivery must reconcile, definite rejection must roll back. Exercise
   delayed old active sync, Restore immediately followed by Trash, and late bulk
   Restore responses. No duplicate, active ghost or checksum-changed local reupload.
4. Restore single/bulk. Check capture timestamp/timezone, chronological grouping,
   album links and pair identity. A intentionally deleted device file must not be
   recreated; the remote item is visible without a duplicate server asset.
5. Permanent deletion defaults to denied for every scope. Verify bytes intact and
   truthful blocked result. Separately approve only the disposable owner/library,
   then permanently delete selected fixtures with confirmation. Verify exact file
   absence, durable complete receipt and no change in other files/users. Inject
   read-only/permission/network failure safely in isolated fixtures; no guessed
   all-success. Retry after revocation must stay blocked.
6. For paired media verify still+owned exclusive motion deletion; shared/wrong-owner
   companion remains protected and a failed motion unlink retains the still row.
   On physical iPhone validate PhotoKit limited/full/iCloud-only; on S23 verify
   Android MediaStore denial/partial result. No fake Android/iOS parity claim.
7. Restart application and, after separate approval, server; rescan only the
   disposable external library. Re-offer byte-identical deleted local/NAS media and
   verify owner-scoped suppression. An arbitrary edited file is a new identity,
   not an automatically provable deleted original.
8. Verify update preserves auth/settings, normal backups, manual albums/stacks,
   search/face recognition, still/video playback and unaffected users. Compare
   unchanged PostgreSQL/Redis/ML and unrelated HP service health.

Any original-safety, owner-isolation, restore-correctness or rollback failure is a
release blocker. Stop before enabling family-library permanent deletion. Current
POSIX unlink has no conditional-by-inode primitive: an independent writer swapping
entries at the final check/unlink boundary is outside the guarantee. Only opt in
controlled exclusive roots after disposable NFS validation; never broaden permissions.
