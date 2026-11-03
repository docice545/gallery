# FOTO Build 37 — Android and iOS gallery UX: Codex implementation brief

**Repository:** `docice545/gallery`  
**Target branch:** `codex/foto-build37-android-ui` (historical name; scope now includes iOS).  
**Scope:** implement and verify Android **and iOS** parity, not Android-only. This is a specification, not evidence of implementation. Inspect the actual code and Build 36 changes before starting. Do not blindly merge or reset branches.

## Interaction contract — do not conflate album and photo swipes

1. **Custom Samsung Gallery-style bottom photo actions panel:** preserve our custom UI, not a stock replacement. Single tap on the full-screen image toggles visibility of the panel; left/right swipes in the photo viewer navigate photos only, never reveal the panel or delete photos. Pinch-to-zoom/pan must not trigger panel or photo changes unexpectedly. Fix lower-panel layout, safe areas, overlays, and touch targets on Android and iOS.
2. **Delete an individual photo:** ONLY tap the trash icon in the custom photo panel. Animate the selected photo **curling/rolling into a tube, rotating, shrinking, and flying to the trash icon**, targeting **500–700 ms** subject to smoothness/accessibility and performance verification. On successful backend/local move to recoverable Trash, show next valid photo or correct empty-state navigation. Do not imply success on API failure; support cancellation/rollback as appropriate and avoid duplicate requests. No photo-delete swipe in feed or viewer.
3. **Delete a DEVICE album from its album list:** swipe **LEFT on the album row/card** to reveal its delete affordance without entering the album. Tap the affordance → confirmation **«Удалить альбом?»** → apply correct local/OS album deletion semantics and permissions. Cancel must preserve it. Do not automatically delete underlying photo assets unless the existing product contract explicitly requires and the user confirmed that destructive scope. The album-cover deletion animation should also roll/curl, rotate and shrink the cover before flying toward the trash affordance (target **500–700 ms**); ensure the actual album deletion only completes after the relevant operation succeeds.
4. **Last photo of a device album:** when deleting photos reduces an opened local/device album **2→1→0**, close the viewer/album and return to the device albums list, refresh counts and covers, without blank/black screen, invalid index or hanging loader. An empty album may remain in the list if supported by the platform and product contract; never silently delete it. Nonempty albums navigate to a valid next/previous photo.
5. **Stacks:** deleting a collapsed stack cover from the timeline targets the entire selected stack; deleting a chosen frame from inside the viewer targets only that frame. Validate cover reassignment, album membership, restore from Trash and associated media.
6. **Live Photo:** inspect and preserve photo/video pairing and metadata; enable **still-frame editing** where editing tools were previously unavailable; save edited still image as a **separate copy** while **preserving the original Live Photo unchanged** (including its motion component). Verify edit entry, save, reopen, export, trash/restore and playback. Do not claim iOS Live Photo editing parity without real-device verification. If native capabilities differ, document the difference and obtain an explicit product decision rather than silently dropping the feature.
7. **Sync and error paths:** Android, iOS, Web Viewer and Backend must agree on item IDs, album counts, trash state, restore, permissions, offline behavior, network errors and conflict resolution. Never present an irreversible delete as recoverable.

## Performance, timeline and panel invariants

- Preserve the **existing stack transition animation at 220 ms**. This is distinct from the new 500–700 ms roll-to-trash animation; do not globally change animation durations.
- Preserve Timeline and Viewer scroll/selection position, thumbnail/album cover state and caching across photo deletion, album navigation and back/forward transitions. Avoid image flashes, repeated downloads, stale cover or unexpected scroll-to-top.
- Fix bottom action panels with correct **SafeArea**, Android system navigation/gesture inset and iOS home-indicator inset, keyboard/overlay interactions, orientation and device sizes. Avoid obscured buttons, phantom touches and duplicated toolbars.
- Treat UI performance and regression as a **separate measured stage after the Build 36 release validation**, not an excuse to rewrite stable features or modify Build 35 production.

## iOS IPA / SideStore is mandatory

- The release is **not complete with APK alone**. Provide a real **IPA** installable via **SideStore** on a compatible iPhone. Verify actual installation, launch, backend login/network access, photo browsing, albums, trash/restore, Live Photo behavior, custom panel/animations, background/foreground lifecycle and local data persistence.
- Audit the existing iOS project and native plugins; verify iOS bundle ID, minimum OS, entitlements, privacy usage strings and permission prompts. Do not assume Flutter/Android features work on iOS without adaptation and device tests.
- Produce the IPA through a compatible **macOS + Xcode** environment or authorized CI with appropriate Apple signing. Do not fabricate an IPA on HP Ubuntu or treat an unsigned zip as installable. Check SideStore-specific signing/re-signing/refresh constraints and report prerequisites/blockers accurately.
- Do not expose or commit Apple certificates, provisioning profiles, passwords, keys or SideStore credentials. Provide artifact SHA-256, build metadata, device/install test evidence and exact release instructions.

## Implementation, tests and safe Git checkpoints

- Codex Cloud works through GitHub on this Build 37 branch; HP is reserved for build/signing/verification steps it can actually support, and is not a macOS/Xcode substitute. Start by fetching and inspecting both target Build 37 branch and Build 36 source/requirements. Record which behavior already exists, which is broken and which is missing. Do not overwrite uncommitted work or merge blindly; preserve other worktrees including `/opt/gallery-fork`.
- Implement in small independently testable stages: panel/gestures; photo roll-to-trash; album left-swipe/confirmation/cover animation; zero-item navigation; stacks; Live Photo; cross-platform parity; signed Android APK and iOS SideStore IPA; integration tests and release documentation.
- For every completed logical stage: review changes, run relevant tests, `git commit`, `git push`, verify remote SHA, and report exact commit and test results. Never push secrets, force-push, or reset unrelated work.
- Tests must cover album counts 2→1→0, single-photo album, album swipe cancel/confirm, no photo-delete swipes, next/previous navigation, stack cover versus single frame, Live Photo, offline/error paths, restore and real-device animation behavior.
- Keep production Build 35 untouched until a separately approved release/cutover. Backend Docker, Android APK and iOS IPA each have independent readiness gates. An incomplete IPA must be reported as blocked, not silently omitted.

**Coordination:** Build 36 production instructions live in `docs/FOTO_BUILD36_CODEX_HANDOFF_20261103.md` on `integration/foto-build36-hp-web-viewer`. The historical Build 37 branch name contains 'android' but this document explicitly expands the release requirements to **Android + iOS**. Do not infer that publishing these documents builds or deploys artifacts.
