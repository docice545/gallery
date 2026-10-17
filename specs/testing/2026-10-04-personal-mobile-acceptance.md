# Personal mobile client: native and staging acceptance

Design and production integration contract: [personal mobile design](../2026-10-04-personal-mobile-design.md).
Use a staging server built from the matching fork commit, disposable accounts/photos and normal owner
API identities. These scenarios do not authorize production access, a release or store publication.

| Scenario | Expected result |
| --- | --- |
| Memories photo at contained scale | Horizontal drag changes asset; vertical drag changes memory; tap halves navigate normally. |
| Two-finger pinch in either direction | Photo zooms without changing asset/memory. |
| Double tap; drag at zoom; return to contained scale | Double tap zooms; drag pans even at the edge; returning to contained scale restores paging. |
| Move between memories, close/reopen | Inactive photo resets zoom and cannot leave paging locked. |
| Video in a mixed photo/video memory | Existing autoplay, controls, timing and progress behavior remains intact. |
| Timeline stack of 5; remove member; dissolve | Badge includes cover, updates to 4, disappears after dissolution; all photos survive. |
| Add selected photos to an existing stack | Existing cover stays primary; server membership and mobile/web views agree after synchronization. |
| Merge selected stack primaries; choose another cover | Members merge using standard API; new cover appears everywhere after sync. |
| Remove current primary from a 3-member stack | A replacement becomes primary before the old cover detaches; no photo deletion. |
| Remove a member from a 2-member stack | Stack dissolves; both photos remain. |
| Stack write while offline or rejected by server | Cache does not claim a successful server decision; retry after connectivity returns. |
| Dissolve/exclude, rerun auto maintenance | Suppression persists; automatic:true creation is rejected. Manual regrouping remains allowed. |
| Different user/shared-space editor | Cannot create a new stack containing another owner's photos or write their suppression history. |
| Enrich on_this_day/month recap/external AI memory | Same ID/assets/year/context/rule identity; title/subtitle displayed on mobile/web; clearing title restores localized fallback. |
| Proposed memory save/dismiss/later on Android then iOS | Decision comes from server; saved appears in ordinary carousel, dismissed never returns, later returns after one day. Reinstall retains state. |
| Retried/reordered/near-identical proposal | Exact retry is idempotent; dismissed or >=0.8 asset overlap conflicts; external generator also handles visual equivalents/new IDs. |
| Hidden/archived/removed candidate assets | Candidate follows ordinary timeline privacy; empty older candidates cannot hide new valid proposals. Saving a removed memory conflicts. |
| Android/Samsung automatic backup | Selected camera albums upload with existing permissions; interrupted upload resumes under existing WorkManager behavior. Check battery restrictions on device. |
| iOS PhotoKit full/limited/denied permissions | Existing permission/library behavior works; limited access does not expose unselected photos; background upload follows OS scheduling. |
| Share/Open with multiple images/videos, unavailable temporary file | Accessible supported attachments import once; unavailable/unsupported entries do not crash the entire import. |
| Export/save and outgoing system share | Photo/video reaches device library/Photos; existing share sheet receives the selected media. |
| Existing immich/my.immich.app links | Existing supported links resolve as before. Self-hosted universal links require separately validated domain association and signing. |
| Display names | Android main/debug launcher and system intents show Фото; iOS launcher/share extension shows Фото; IDs/icons remain their existing values. |
| Notifications | Candidate card works without push. Existing server/web notification is recorded; OS background alerts require configured delivery and device testing. |

Linux cloud widget tests cannot establish PhotoKit/native-video correctness, Samsung scheduling,
physical multi-touch feel, native permission prompts, signed universal links or OS push delivery.
A matching Android SDK/NDK/JDK and macOS/Xcode for iOS are required for native compilation. Before an
APK, regenerate the artifacts from mobile/mise.toml, run formatter/analyzer/affected tests, build a
local unsigned debug artifact, and execute the device scenarios above. Keep all production scripts
unchanged until their documented integration has been reviewed on staging.
