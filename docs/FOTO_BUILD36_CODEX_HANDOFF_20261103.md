# FOTO Build 36 — Codex handoff and release requirements

**Repository:** `docice545/gallery`  
**Working branch:** `integration/foto-build36-hp-web-viewer`  
**Verified starting commit (2026-11-03):** `fda0ef2004bfb0e7f5908eda51e45a817c7be2e2`

> This document records requirements, not a claim that the features are implemented, tested, or released. Always verify the actual repository and HP runtime state first.

## 1. Mandatory UX: distinct photo and album actions — do not conflate gestures

The project uses its **custom Samsung Gallery-style photo action panel**. Preserve the existing custom panel and its layout; do not replace it with a generic toolbar.

**Only the trash button in that panel initiates moving the currently selected photo to Trash.** Do not introduce any swipe-to-delete PHOTO gesture in the timeline/feed, full-screen photo viewer, or stacks. This restriction DOES NOT apply to the explicitly required left-swipe on an ALBUM ROW in the device-albums list, which reveals the album-delete action (see section 1A). Ordinary photo horizontal navigation and zoom gestures must remain unchanged.

**Required visual effect on trash-button activation:** the displayed photo **rolls/curls into a narrow tube**, shrinks, and **flies toward the trash icon**. The animation must be smooth, with no flicker, blank frame, or accidental animation of other photos. The actual operation is **move to recoverable Trash**, not permanent deletion.

**Operation sequencing and failure handling:** follow the established confirmation UX if one already exists. Do not visually imply a successful deletion until the move-to-Trash operation succeeds; an optional anticipatory animation must be reversible on error. On success, remove only the intended asset from the current view and smoothly show the next valid photo or an appropriate empty state. On failure, keep/restore the photo and display an error. Prevent duplicate taps and concurrent deletion requests.

**Special cases:** preserve correct behavior for individual photos within stacks, albums, Live Photos (including their associated media), and synced assets. **Agreed stack semantics:** deleting the selected collapsed stack COVER from the TIMELINE moves the entire selected stack to Trash; deleting the selected FRAME from inside the VIEWER moves only that frame to Trash. Do not accidentally delete a whole stack when the viewer's selected frame is targeted, or orphan a Live Photo component. Preserve and test stack primary-frame reassignment and correct restoration of stack relationships. Verify restore-from-Trash, Android/Web Viewer/Backend consistency, and offline/network-error behavior. Respect existing API semantics; inspect them before changing anything.

**Acceptance checks:** no swipe-to-trash code or gesture; action triggered by custom-panel trash button; curl/tube-and-flight animation visibly targets trash; successful recoverable move and correct next-photo navigation; failure recovery; stack/album/Live Photo coverage; automated tests where feasible and manual Android animation verification.

## 1A. Device albums: swipe-left on ALBUM row, confirmation, and zero-item state

This is a **different interaction from deleting a photo** and must not be removed by the no-photo-swipe rule above.

- On the **device albums list**, swipe **left on an album row/card** to reveal a trash/delete affordance **without opening the album**. Do not make this gesture delete an album immediately or apply it to individual photo thumbnails.
- Tapping the revealed delete affordance must show an explicit confirmation dialog **«Удалить альбом?»** (or the established localized equivalent). Cancel preserves the album and its contents.
- On confirmation, use the correct existing device/OS and server APIs as applicable; respect permissions, album membership, local-versus-server ownership and sync semantics. **Do not assume deleting an album means irreversibly deleting all of its underlying photos**: inspect and preserve the project's established contract, and clearly distinguish album removal from moving assets to Trash. Handle permission denial and partial failures without falsely reporting success.
- After successful album deletion, refresh the device-album list and counts; the removed album must no longer appear. Avoid stale thumbnails, duplicate entries and navigation to an already deleted album.
- If deleting the **last photo** of an **opened local/device album** reduces its contents to **0**, close the empty viewer/album and navigate back to the **device albums list**, refreshing counts and thumbnails. Do not leave a black/blank photo viewer, an invalid index, a spinner, or a dead-end empty screen. If the album still exists as an empty album, its list presentation must follow the app's existing empty-album policy rather than being silently deleted.
- For a nonempty album, after a photo is moved to Trash, show the next valid photo (or previous if at the end), with safe indices and no accidental removal of adjacent assets. On failed deletion, preserve current navigation and counts.
- Regression-test counts **2→1→0**, deleting the only photo, deleting an album from the list via left swipe and confirmation, cancellation, device permission errors, server/sync partial failures, and return navigation.

## 1B. Photo viewer gestures and panel visibility

- **Left/right swipe in the full-screen photo viewer is ONLY for photo navigation**; it must not delete a photo and must not reveal the Samsung-style action panel.
- **Single tap** toggles the custom toolbar/panel according to existing UX.
- **Pinch/zoom/pan** must not unexpectedly show the panel; while zoomed, panning the image takes precedence over changing photos.
- Do not add deletion gestures to the timeline/feed or full-screen photo viewer. The custom-panel trash button remains the photo deletion entry point.

## 2. Build 36 release scope

Deliver **(A)** a complete production Docker Backend Build 36 including server, Web Viewer, SDK, CLI, and required plugins, and **(B)** a release-signed FOTO Android APK with `versionCode=36`, updating Build 35 in place without uninstall or data loss.

Starting facts supplied by the HP operator: source branches were already integrated; working tree clean at the verified starting commit; Web Viewer tests 41/41 PASS and TypeScript/Svelte checks PASS at that checkpoint; production Docker Build 35 Healthy and API HTTP 200. Re-run checks as needed after changes. Do **not** repeat merges, generate new signing keys, or bootstrap the project from scratch.

Discover existing build scripts, Docker configuration, signing properties, and rollout mechanisms from the repository and HP environment. Do not invent paths or claim artifacts exist before verification. Preserve production Build 35 until Build 36 is built, validated, and explicitly approved for cutover. Back up deployment configuration and data; provide a tested rollback plan. Check Android signing certificate continuity against Build 35 without exposing secrets; verify APK package ID, `versionCode=36`, signature, and in-place update on a test device.

## 3. Mandatory Git checkpoints — never lose work

Before starting: verify repository, branch, `HEAD`, working tree, and GitHub remote; fetch and compare histories. Do not overwrite other worktrees or uncommitted changes. Separate work in `/opt/gallery-fork` (Magic Eraser, with uncommitted files) is **not automatically part of Build 36** and must not be reset, cleaned, or merged blindly.

After **every completed logical stage**, inspect the diff and staged files, run relevant tests, then `git commit` and `git push` to the intended remote branch; verify remote SHA equals the pushed commit. Save a checkpoint before risky operations, and preserve even partially completed work in a clearly labeled WIP commit/branch if necessary. Never commit Android keystores, signing passwords, tokens, private keys, `.env` or other secrets. Do not use `git push --force`, destructive `reset`, or indiscriminate `git add -A` without reviewing staged files.

After each stage report: commit SHA, branch, push verification, tests and results, unresolved risks, and next action. Git commits are source checkpoints, **not** substitutes for APK/image/database backups.

## 4. Suggested execution order for Codex

1. Fetch the specified branch and inspect the current implementation of custom panel, photo trash API, device album-row swipe-left deletion and confirmation, zero-item album navigation, viewer transitions, stacks, Live Photos, and tests. Document any gaps; do not assume the animation already exists.
2. Implement only necessary changes to meet the button-only PHOTO trash interaction and roll-into-tube/fly-to-trash animation; preserve album-row swipe-left delete with confirmation, viewer navigation gestures, and 2→1→0 local-album exit behavior. Test normal, failure, and special cases. Commit, push, verify SHA.
3. Verify complete Build 36 backend image contents and build using existing tooling. Validate health, API, Web Viewer, SDK/CLI/plugins and regression tests in isolation. Commit source/build-script changes, push, verify SHA.
4. Build and validate release-signed Android APK `versionCode=36` using the **existing original keystore**, without exposing or committing it. Test installation over Build 35 without data loss. Commit source/config changes, push, verify SHA.
5. Produce reproducible release notes, artifact hashes, verification commands, backup/rollback steps and an explicit go/no-go recommendation. Production cutover requires operator approval.

**Important:** This is a task specification for Codex; publishing it does not build Docker, sign an APK, deploy production, or launch Codex automatically.
