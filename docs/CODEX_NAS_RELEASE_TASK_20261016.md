# Codex Web task: Gallery release readiness (2026-10-16)

**Target:** Finish the Gallery app's mobile/web UX and backend into an installable, tested release with correct, safe Synology NAS external-library behavior. Work on a feature branch and open a PR. **Do not deploy to the production HP server, merge automatically, or delete real family photos.**

## Verified production evidence

- Gallery 5.7.3 is healthy on HP Ubuntu/Docker. Current production image: `sha256:1b6ee28e2b868280a9787cef5533636736de1148a18d2915ca5ff42835362bef`, built from `8af3a7a923c1391474dc9b7410e2f7833bc7771d`. Previous image: `sha256:52e08a50b507ddddf591706eed8df70c1904b47fca53d5e913146853df2a2b8b`.
- **SSD Live Photo permanent deletion PASS:** JPG ID `879970f2-b440-4afd-b320-55c8f542ed7b`, linked MP4 ID `850b7905-5297-4436-8640-57ff7210abbd`: after single-item "Delete permanently" from trash, SQL returned zero asset rows and both physical files were absent at `/data/upload/...` and `/data/encoded-video/...`. **Not a NAS test.**
- **Fresh Galaxy S23 Live Photo `20261016_100303`:** JPG ID `01af05b5-68da-4169-86a5-1721277ba580` at `/data/upload/de9b2d19-cd6a-4b82-8230-33e17134a3bf/2f/c3/2fc3f68b-bf68-461b-b668-9742b7a4ded9.jpg`; linked MP4 ID `fab55391-e835-49e6-99f2-2e36310dbfbc` at `/data/encoded-video/de9b2d19-cd6a-4b82-8230-33e17134a3bf/fa/b5/fab55391-e835-49e6-99f2-2e36310dbfbc-MP.mp4`. `find /external` found neither filename. This does **not** prove no other copy exists on Synology; it proves Gallery's indexed copy is SSD-backed and no matching file was visible under the mounted `/external` tree at that time.
- `20261015_073059.jpg` in trash also had `/data/upload` JPG and `/data/encoded-video` MP4. Not NAS-backed.
- **Existing NAS/SSD split is real:** `/external/docice/MobileBackup/S23 пользователя Андрей/DCIM/Camera/2026/09/20260926_125932.jpg` paired with `/data/encoded-video/de9b2d19-cd6a-4b82-8230-33e17134a3bf/50/9f/509f0ead-4440-44af-934e-152a9cd60fdb-MP.mp4`. This is genuine family archive; NEVER delete for testing.
- **NAS physical deletion is NOT TESTED.** ~1389 items already in trash, so never run global Empty Trash as a test. NFS unlink permissions, snapshots and backup restore are unverified.
- Production Compose pinned the new image in `/opt/immich/docker-compose.yml` because `hp-data-apps.service` reverted a temporary Compose override. Backup `/opt/immich/backups/manual-20261016-064401/gallery.dump` passed `pg_restore --list` but has not been restore-tested. DB downgrade/rollback not validated.

## Work items

1. Audit repository implementation, architecture, UI, storage and Live Photo pairing; distinguish Gallery direct upload from Synology Photos MobileBackup and external library indexing. Determine why fresh phone uploads use `/data/upload`, document supported NAS workflow and user-facing expectations. Do not silently change all upload destinations or assume a Synology copy should exist.
2. Implement **explicit safe external-library delete policy**. Default read-only/no physical NAS delete. Opt-in authorized source deletion with clear UI warnings; robust path containment, symlink/mount protections, permissions, NFS failure handling, idempotency, retries, job state, and auditability. Distinguish deleting from Gallery index vs physical Synology original. Correctly manage NAS JPG + SSD linked MP4, including trash/restore/permanent deletion/rescan and partial failures. Never delete unrelated media.
3. Finish mobile/web UX and backend: intuitive storage/source information, trash and restore, safe single-item permanent deletion, clear progress/errors, Russian localization, accessibility, responsive UI. Preserve existing features.
4. Add automated integration/e2e tests using **disposable data**: SSD/SSD; NAS JPG+SSD MP4; read-only or missing/unmounted NAS; partial failures, retries, concurrent rescan, duplicates, security/path traversal, restore and retention. Verify actual files and database state. Explicitly label mocked tests vs real NFS-mounted tests; do not claim real Synology tests without access.
5. Prepare clean reproducible release: Docker image build/digest, Compose/example environment, install/update guide, migration/backup/restore instructions and limitations, CI tests/lint/security checks, release notes, test matrix and exact logs/results. Never promise downgrade compatibility without evidence.
6. Create a PR with code, tests, documentation, blockers, and objective pass/fail acceptance evidence. No automatic merge/deploy.

## Acceptance

- With disposable fixtures, a Live Photo whose JPG physically resides on NFS-backed `/external` and linked MP4 on SSD `/data` can be trashed, restored and permanently deleted under an explicit authorized policy, with physical and DB checks; other files untouched.
- External-library deletion is disabled by default, with clear UX and safe failure modes.
- All claimed tests actually run and pass; installation artifact and complete docs are available.
- If real Synology access is needed, state **pending real-NAS validation** rather than asserting success.
