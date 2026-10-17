# S23 CloudMediaProvider, Trash integrity and HP video acceleration

Baseline: `42790b06edc21438811e56e40c431eee37c24894`. This is a focused continuation;
the previous integration/Android/iOS builds are not repeated. The owner reports
an HP-key-signed 5.7.2 (7) installed on S23/Android 16. This audit has no physical
Samsung/iPhone or HP access. Changes stay on a separate review branch; no `work`
merge, release, production changes, historical Memories analysis or Anna migration.

## A. Admission is different from implementing a provider

Android 16/QPR1 MediaProvider release `android-16.0.0_r3`, commit
`78a0bebdc478a3e827618944f9998c5e21fc9712`, retains these gates:

- `ConfigStore`: `cloud_media_feature_enabled` AND a nonempty
  `mediaprovider/allowed_cloud_providers`; `cloud_media_enforce_provider_allowlist`
  defaults to true.
- `CloudProviderUtils.getAvailableCloudProvidersInternal`: resolve the provider
  intent, require an authority and the correct `ProviderInfo.readPermission`, then
  exclude packages not in the allowlist. A manifest is necessary, not sufficient.
- `PickerSyncController.setCloudProvider`: applies admission during ordinary
  selection. `forceSetCloudProvider` is a special override, not a public enrollment API.
- `MediaProvider.getResultForSetCloudProvider`: system's own UID or shell only.

Primary references:

- [AOSP discovery](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/78a0bebdc478a3e827618944f9998c5e21fc9712/src/com/android/providers/media/photopicker/util/CloudProviderUtils.java#L114-L159)
- [AOSP configuration](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/78a0bebdc478a3e827618944f9998c5e21fc9712/src/com/android/providers/media/ConfigStore.java#L376-L389)
- [AOSP selection](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/78a0bebdc478a3e827618944f9998c5e21fc9712/src/com/android/providers/media/MediaProvider.java#L8032-L8049)
- [Public CloudMediaProvider contract](https://developer.android.com/reference/android/provider/CloudMediaProvider)
- [Public Photo Picker integration](https://developer.android.com/training/data-storage/shared/photopicker)

The official reference URLs are entry points; the version-pinned AOSP source is the
examined evidence. Samsung's current module/configuration is not accessible here.
Its observed Google Photos/None list is consistent with filtering, but does not by
itself reveal the precise allowlist, feature flag or OEM-specific additional gate.
No documented public API was found by which this normal sideloaded package can
enroll itself. Play publication/platform signing cannot be inferred as either
sufficient or intrinsically necessary from the AOSP discovery code. Native
zero-intervention registration cannot be promised for this S23.

### Repository contracts checked

`AndroidManifest.xml` declares `de.opennoodle.gallery.cloudmedia`, exported, with
both read/write protection `com.android.providers.media.permission.MANAGE_CLOUD_MEDIA_PROVIDERS`
and `android.content.action.CLOUD_MEDIA_PROVIDER`. The signature permission protects
access **to** the provider; Gallery need not hold it to implement the provider, and
declaring it does not grant system-policy write access. The component is enabled
only through `values-v35`; this pilot uses API 35+ although base CMP APIs began at 33.
No authority/application ID or permission change is needed to fix discovery.

`GalleryCloudMediaProvider`, `CloudMediaCatalog`, `CloudMediaChanges`, `CloudMime`
and `CloudRangeReader` use the existing authenticated session and Drift WAL, not a
second importer/REST index. Owner/endpoint/session-scoped IDs reject old-account URIs.
The SQL projection excludes Trash, Locked, hidden motion components, unauthorized
partners/Spaces, user-hidden entries and non-primary stack children. Album queries
respect access/membership. MIME filters use the original bytes' format. Media pages
are bounded (max 200 plus continuation); page tokens include the collection version.
Collection changes force a full picker snapshot, rather than inventing deletion deltas.
Hashing streams rows but scans the eligible catalog/album tables on changes: >30k
performance and OEM resync cost remain physical acceptance items, not benchmarks.

Original opens recheck server ACL/Trash/visibility, then provide a seekable, bounded
range reader with cancellation and session/visibility checks on subsequent reads.
No full video in RAM or whole-library original download. Preview transfers are
bounded, concurrency limited and temp files owned/cleaned. A Live/Motion item is one
logical still; the hidden companion is not offered as an independent video. An
Apple HEIC+MOV pair is not promised as a full Live Photo through Android's picker.
Server/original embedded Samsung bytes are not rewritten. Timeline autoplay is untouched.

### Existing privileged pilot and its limits

The app's local opt-in, system admission and selected provider are separate states;
`MediaStore.isSupportedCloudMediaProviderAuthority`/`isCurrentCloudMediaProviderAuthority`
check the real system, not a successful command alone. Activation currently requires
Shizuku UserService running as shell UID 2000, including the Enable command for an
already-admitted package. A bare ADB allowlist edit is therefore not a complete
replacement for the app's opt-in workflow. This audit does not silently add one.

Android 16 local DeviceConfig overrides are persisted by SettingsProvider. Normal
provider queries/content reads do not call Shizuku: one-time activation can therefore
work with Shizuku subsequently stopped. Reboot persistence is supported by the AOSP
storage design, not yet empirically proven on this One UI module. OTA/module updates,
reset, policy replacement or another Android user can invalidate admission. App
updates should retain preferences with the same ID/certificate; uninstall clears them.

The existing journal is committed before either of two protected writes. It preserves
the existing allowlist/selected provider, validates shell caller and Android user,
recovers partial activation/undo, handles legacy journals and refuses to overwrite
external edits. Disable immediately stops this account's exposure even without
Shizuku; privileged Undo remains pending until shell access returns. Do not clear
the journal or globally disable allowlist enforcement to make the UI look successful.
No root, rish, PC or daily privileged service is involved in ordinary reads.

### Shortest realistic S23 acceptance

1. Record One UI/build and Photo Picker/MediaProvider module version. Confirm the
   installed APK is the HP-key update; no uninstall, account reset or reimport.
2. Confirm baseline Google Photos remains listed. Without Shizuku, record Gallery's
   automatic status; absence is not cured by repeatedly pressing Enable.
3. If the owner chooses the existing pilot: start official Shizuku through Wireless
   debugging/pairing on trusted Wi-Fi, authorize Photos, then explicitly Enable.
   No shell mutations are performed by this investigation.
4. Require `admitted=true`; open normal cloud media settings. Gallery must appear
   **alongside** Google Photos. Select Gallery manually; require `selected=true`.
   If still absent, stop and capture diagnostics/module version; do not force-disable
   platform protection or pretend the provider has been selected.
5. Stop Shizuku and turn Wireless debugging off. In an app which actually launches
   `ACTION_PICK_IMAGES`, select a server-only photo, then a video; verify original
   transfer, MIME, seek/cancel/offline behavior. Telegram's private gallery may be
   MediaStore-only and is not this test. Share/Download remain available there.
6. Repeat after reboot and same-key APK update. Check both listing and actual reads.
   If admission survives, no Shizuku restart is needed for normal use; do not promise
   this until the S23 check succeeds.
7. Verify Trash/Locked/hidden companion suppression, account switch with an old URI,
   album paging and a large library. Check Disable with Shizuku off, followed by
   explicit journal Undo when it is running again. Google Photos must remain available.

## B. Independent deletion/restore trace and corrections

| Scenario | Code/fixture evidence | Physical limitation |
| --- | --- | --- |
| Single/bulk photo or video Trash | DeleteAction → AssetService → serialized DELETE `force=false`; optimistic Drift update and durable revision; same type-independent path | Server setting/permission and actual native dialogs need device validation |
| Definite rejection | Known HTTP rejection rolls back its captured optimistic revision | Must test real offline/reconnect without assuming request reached server |
| Timeout/network/5xx | Durable uncertain marker, restart and reconnect reconciliation even with no incremental asset event; old snapshots cannot override in-flight revision | Expired/deleted IDs may need the subsequent authoritative delete sync event |
| Single/bulk Restore | PATCH Trash API; original capture/localDateTime/EXIF/timezone/album rows retained, no reimport | Date display reflects existing metadata, not a repair performed by Restore |
| Restore then Trash | REST order serialized; late acknowledgements use captured revision and cannot clear newer Trash | Physical background/native interaction still unverified |
| Timeline/pagination | Reactive Drift buckets reload TimelineService buffer; capture order, deterministic IDs for ties, matched local subtraction | Selection/scroll UX must be checked on S23 |
| Search/filter cache | Previously retained static server pages; corrected to observe current endpoint's durable markers, including missing-row reset windows | Cleanup/folder deep-link one-off asset lists are separate snapshots; reopen/refetch may be needed |
| Albums | Soft deletion retains `album_asset`; query visibility excludes trash and Restore re-exposes existing membership | Removed-from-album is a distinct operation, not Trash; removed membership is not recreated |
| Live/Motion | Still `livePhotoVideoId` remains during Trash/Restore; hidden companion excluded from main/CMP; permanent cleanup removes an unreferenced companion | OEM embedded-motion/PhotoKit Recently Deleted behavior is not simulated |
| Local-only asset | Platform PhotoManager; Android MediaStore Trash where supported, otherwise native delete; only returned IDs change local rows | iOS recovery is through system Recently Deleted; not an invented Gallery local-restore API |
| Local+cloud copy | Immediate server Trash preserves local original; with explicit Android Manage Local Media enabled, later sync can move matched backed-up local copies to native Trash and restore them | With this option off, Samsung Gallery/local picker can still show the device copy; CMP cannot hide arbitrary MediaStore items |
| External-library Trash | Backend initially only changes `status`/`deletedAt`, like managed assets | NOT a perpetual promise to preserve writable NAS originals |
| Permanent/expired Trash | Background job removes DB metadata, generated files and, when requested and online, original+sidecar; offline/library-removal path can use `deleteOnDisk=false` | A writable external NAS mount permits physical removal; retention disabled means zero-day retention |

Two confirmed defects and one related acknowledgement defect were corrected:

1. Search/filter pages did not observe Trash. Cached and delayed pages now apply
   existing markers; restore returns the retained result without a refetch or duplicate.
   Initial results fail closed until markers arrive. The subscription is cancelled on
   disposal. Clearing a previously observed marker on permanent deletion/reset cannot
   reveal an old cached tile while its row is absent. Only an active row can reveal
   that retained result again. This check is a bounded local ID lookup, with no extra
   server request or media decoding. A fresh search after disposal uses fresh server
   results; other one-off asset-list surfaces still have the snapshot limitation above.
2. Retention sweep jobs captured an ID but did not revalidate expiry after Restore.
   New jobs carry an ISO cutoff. Before stack changes, metadata removal or FileDelete,
   one conditional SQL UPDATE claims only a row whose current `deletedAt <= cutoff`.
   Restore clears the date; a new Trash after the cutoff is not claimed. The UPDATE
   serializes against Restore; once it wins, `Deleted` is the irreversible boundary.
   Malformed cutoffs fail closed; deadlock requeues keep the cutoff. Library removal
   and hidden-motion cleanup retain their existing independent contracts.
3. Batch Restore announced every requested ID, including rows not actually restored.
   UPDATE RETURNING now produces actual IDs for events/tombstone cleanup and count.
   HTTP DTO/routes remain unchanged. The client treats incomplete selected-batch
   counts as uncertain. A Restore-All count cannot identify each captured row, so
   its marker remains pending for normal per-ID reconciliation, with revision guards.

No DB schema/migration, original-file modification, new sync service or retention
policy change. Server-side corrections require a future reviewed server update;
they are NOT installed on the HP. The deletion-only continuation now makes legacy
jobs without a cutoff fail closed for Active/Trashed rows and adds explicit guarded
library/motion cleanup intents. No old payload is guessed or erased. The existing
FileDelete backlog remains an operator safety gate. See
`specs/2026-10-09-trash-release-safety-design.md` for the transition and rollback.

### NAS safety and acceptance boundary

`AssetService.deleteAll` does not unlink originals for ordinary Trash. However
`handleAssetDeletionCheck` and `TrashService.handleEmptyTrash` can queue irreversible
deletion; `handleAssetDeletion` does not exclude external-library originals when
`deleteOnDisk=true` and `isOffline=false`. A read-only NAS mount prevents successful
unlink, but does not promise preservation of Gallery DB metadata/album links after
permanent removal. An offline external file is a different condition; restoration
does not make it reachable or replace the need for a scan after path/access repair.

Physical testing may proceed **only with disposable non-sensitive fixtures**, Trash
enabled and retention known, using normal Trash/Restore. Do not test Empty Trash,
zero-day retention or permanent deletion on family/NAS originals. Verify original
bytes remain unchanged, timeline/album/search disappearance and chronology on Restore,
then restart/offline/reconnect/Restore→Trash. Repeat ordinary video, Apple-origin Live
and Samsung Motion with Manage Local Media off/on as separate consented scenarios.
No physical acceptance or DB-backed PostgreSQL interleaving test is claimed here.

## C. VAAPI/QSV evidence and the first production diagnostic stage

Historical evidence exists in `CODEX_MEMORIES_VAAPI_TASK.md`: a previous external
`StreamingEncoder`/`assemble_streaming` test reportedly used `h264_vaapi`; most CPU
was still consumed by raw-frame filter/composition processing, with little sustained
Video-engine use. It is a historical result, not verification of today's deployment.
The actual external generator/renderer is outside this repository; this task does
not recreate it, infer video statistics or restart historical AI warmup.

Repository facts:

- `docker/hwaccel.transcoding.yml` contains VAAPI/QSV `/dev/dri` examples, not proof
  that `/opt/immich/docker-compose.yml` currently applies them.
- Config defaults (`server/src/dtos/config.dto.ts`) disable video-transcode acceleration;
  actual persisted/file settings may override them. `server/src/utils/media.ts` has
  software, VAAPI and QSV command paths. Video previews/transcodes are served to clients.
- `MediaRepository.extractVideoFrames` attempts an accessible VAAPI render node and
  falls back to software per extraction failure. JPEG encoding remains software after
  surface download. Automatic frame extraction is distinct from configured video
  transcoding. Node discovery or a passing mocked fallback test is not a GPU benchmark.
- Flutter/Android/iOS use platform video playback and existing server media; timeline
  autoplay is not HP video encoding. Still thumbnails use server Sharp/libvips processing.
- External Memories can compose frames on CPU even with VAAPI final encoding. ML,
  HDR OpenCL filters, Big-LaMa and external AI can contend for CPU/RAM/EU bandwidth;
  fixed-function Video acceleration does not move every filter/AI workload off CPU.

### UHD 630 capability boundaries

Coffee Lake UHD 630 is covered by Intel's KBLx media-driver family. Pin examined
sources rather than treating FFmpeg's compiled codec list as device capability:
[Intel media-driver 25.3.4](https://github.com/intel/media-driver/blob/intel-media-25.3.4/README.md)
and [Intel compute-runtime 24.35 legacy branch](https://github.com/intel/compute-runtime/blob/24.35.30872.36/README.md).

| Operation | Hardware/driver expectation | Not established on HP |
| --- | --- | --- |
| H.264 8-bit decode/encode | Supported by KBLx iHD, including Free-Kernel build | Actual profile/entrypoint and execution |
| HEVC Main/Main10 4:2:0 decode | Supported | Specific iPhone HEVC/Dolby Vision compatibility |
| HEVC 8/10-bit encode | Full-feature iHD supports shader-assisted encode; examined Free-Kernel KBLx table lists decode only | Installed full/non-free driver, VAEntrypointEncSlice and real encode |
| VP9 Profile0/2 8/10-bit decode | Supported; examined KBLx table has no VP9 encode | Current driver's exposed profiles |
| AV1 decode/encode | **No UHD 630 hardware support** | A listed FFmpeg AV1 software encoder does not change this |
| HDR10→SDR | No native KBLx HDR10 TM entry in examined iHD processing table; Gallery VAAPI path uses OpenCL interop tone mapping | OpenCL runtime/interop, colors/brightness/orientation, playback/audio sync; not automatically accelerated just by HEVC Main10 decode |
| Video thumbnails | Hardware decode/scale may help; JPEG output and other filters remain CPU | Real savings and frame correctness |

i915 is the expected Coffee Lake kernel driver. iHD is the modern Media Driver path;
i965/legacy or a free-kernel packaging variant can expose different entrypoints.
QSV is a different FFmpeg/runtime interface to Intel acceleration, not additional
GPU hardware; its legacy Media SDK/oneVPL implementation must support Gen9. Prefer
verifying the actual container VAAPI path before changing QSV/runtime/drivers.
No GuC/HuC/kernel parameter change is proposed from a documentation table alone.

### Read-only HP inventory

Run `scripts/diagnostics/hp_vaapi_audit.sh` as doctoriceadm, default output
`/home/doctoriceadm/gallery-vaapi-audit.txt` (0600). Existing output/symlinks are
rejected rather than overwritten. The script needs only installed Bash/coreutils/
Python; missing optional tools are reported, never installed. It collects:

- PCI/i915/DRM ownership, user/container access, installed driver versions,
  `vainfo` profiles if available, GPU inventory/exposed counters; no media processing.
- CPU/RAM/swap/process **names only**, mounts/capacity, known SSD/cache/model bind
  identities, service states without unit/env contents; Docker root and allowlisted
  Gallery/Immich/ML/Memories container metadata/devices/mounts/Compose labels.
- Actual container FFmpeg PATH/version/codec/filter inventories, not just host FFmpeg.
- Whitelisted config-file overrides, plus ONE bounded PostgreSQL SELECT under
  `default_transaction_read_only=on`/timeouts for ffmpeg/job/Trash settings. Existing
  DB credentials remain inside the container. It does not print credentials or media.
  File/DB overrides are explicitly not mislabeled as merged effective Admin config;
  confirm effective hardware/transcode/thumbnail queues in Admin UI without sharing tokens.

No SSH, installs, driver load, restart, Compose edit, benchmark, rescan, reindex or
production writes. Shell/mocked safety and a cloud-only inventory can validate the
tool, not HP capabilities. Review the TXT for privacy before uploading it. Missing
Docker read rights leave sections UNVERIFIED; authorize local sudo for reads if needed.

After the TXT: identify exact missing mapping/permissions/driver/encoder/config,
propose the smallest correction and its CPU/GPU effect, preserve previous image +
exact changed Compose/config backups, and request explicit approval. Only then use
a short non-sensitive copied sample, one job, no concurrent heavy AI. Verify encoder
selection **and** Intel Video/VideoEnhance/Render counters, CPU, output decode/duration/
orientation/HDR behavior/audio sync/source hash, then software fallback. Rollback
restores only the previous Gallery setting/image/override; external Memories VAAPI
enable/disable is separate. No broad restart, Docker prune or infrastructure changes.
Actual HP deficiency and exact deployment commands remain pending its diagnostic TXT.

### OpenVINO is separate

The ML Dockerfile already supplies an `openvino` image target and Gen9 `legacy1`
OpenCL runtime packages; compatible ONNX CLIP/face/OCR/YOLO models may use its
OpenVINOExecutionProvider when the matching image, devices, driver and model permit.
This establishes feasibility, not that the current HP ML image uses it. iHD video
support does not establish OpenCL/OpenVINO inference. Shared RAM/EU pressure and
model parity require a separate small approved test. Historical Qwen2.5-VL GPU
attempts failed with OpenCL resource/kernel errors; external LLM/VLM and Big-LaMa
TorchScript CPU workloads must not be changed under a VAAPI task.

## Validation boundary

Focused Flutter/Drift/service/action/search tests and full analyzer, server unit/SQL
compilation/TypeScript/lint, and shell/mocked diagnostic safety checks are required.
Real PostgreSQL tests for Restore-before-claim, claim-before-Restore and a new Trash
after the old cutoff are added to `trash-timeline.service.spec.ts`; an isolated
PostgreSQL instance is required to execute them. No production DB or NAS test.
No native Android APK, iOS archive, Samsung/iPhone validation, HP benchmark or
production deployment is part of this investigation.

### Executed checks (Flutter 3.47.2 / Dart 3.13.2)

| Check | Result |
| --- | --- |
| Combined mobile action/API/Drift/sync/CMP/search/Timeline/Photos-filter suites, after the final missing-row/permanent-deletion fix | 594 tests passed across 40 unique files |
| Full Flutter analyzer with fatal infos | No issues found |
| Changed Dart files format check | 10 files, zero changes |
| Full `lib test` format check | Failed only for two existing **ignored** generated localization files (`codegen_loader.g.dart`, `translations.g.dart`); neither is modified/committed |
| Server asset/Trash/controller/media/smart-info suites | 566 tests passed across 8 files |
| Full server TypeScript check; touched-file ESLint and Prettier | Passed |
| Existing admission policy, standalone Kotlin 2.2.20/JUnit | 20 tests passed; not an Android APK/native device build |
| Diagnostic shell syntax/help and Python mocked safety tests | Passed; 5 tests, including overwrite/symlink refusal and read-only/redacted Docker/SQL scope |
| Final diagnostic execution in the cloud workspace | Completed, private 0600 report; missing host tools/devices explicitly UNVERIFIED. Not HP verification |
| PostgreSQL medium tests | Added 3 retention/Restore interleavings, NOT RUN: no isolated `IMMICH_TEST_POSTGRES_URL` binding |
| Generated SQL | Changed Trash snapshot synchronized with offline Kysely/sql-formatter output; full DB-backed SQL/schema generation NOT RUN |

The expanded Flutter fixture initially lacked its real in-memory Drift override;
the fixture was corrected and the complete expanded run then passed. New Kysely
query compilation and mock expectations were corrected before the passing server
checks. Tool initialization/analytics failures were environment failures, not passing
tests. No failing check is relabeled as a success. No full Flutter suite or new CI
release was run.

### Operator handoff for the first HP inventory

Use the single diagnostic block in the task's final report: it downloads this script
from the **exact review commit**, verifies its SHA-256, and runs it as doctoriceadm
to `/home/doctoriceadm/gallery-vaapi-audit.txt`. No checkout/merge on the HP is needed.
`sudo -v`, if used, only authorizes the script's read-only Docker queries; it does not
install anything or change permissions. An existing report must be archived by the
owner before another run. Read the resulting TXT for privacy before uploading it.
Do not run activation, encoding benchmarks, Compose edits or deployment based on
this report alone: the next stage requires diagnostic review and explicit approval.
