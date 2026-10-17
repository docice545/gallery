# Ordinary source videos in Memories: repository evidence and external boundary

Baseline: `75633fc0d0071c18d9e48ce1017e830d8556416d`, 7 October 2026.
The user's observation concerns many completed, photo-only Memories; it is not
evidence that all candidate sets contained eligible source videos.

## Sources actually available

- `work`, `origin/work`, `origin/main`, existing CocoaPods review refs and the
  diagnostic iOS ref were inspected; all local history was searched for
  `StreamingEncoder` / `assemble_streaming` additions or removals.
- The sole renderer reference in history is `30b2d01b41`, adding
  `CODEX_MEMORIES_VAAPI_TASK.md`. It records an **already successful HP runtime
  patch**, not its Python implementation. `fe18abe3a4` / `5802775927` and the
  external-memory audit describe Gallery API integration and suppression.
- Repository files and retained workspace handoffs contain no implementation
  of these two functions, candidate/planner JSON pipeline, renderer container
  definition, sanitised completed-Memory manifest or stage counts.
- Known external integration locations are `/opt/gallery-ai/gallery_ai_memories.py`,
  `gallery-ai-daily.service/timer`, `/opt/gallery-ai/gallery-memory-carousel`.
  **The actual module/container containing the streaming assembler is not
  established by these references.** Do not assume it is the daily generator.

## What Gallery code proves

| Stage                            | Existing code                                                                                              | Proven contract                                                                                                                                                                                                                                          |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Search                           | `server/src/dtos/search.dto.ts`, `services/search.service.ts`, `repositories/search.repository.ts`         | Asset type is an optional caller filter. Smart search requires an existing embedding and applies access/visibility filters. A missing embedding can remove a video independently of the type filter. No external planner's request payload is available. |
| Native candidate rules           | `repositories/asset.repository.ts#getMemoryAssetsForPeriod`, `services/memory-rules/video-moments.rule.ts` | Period queries carry asset type and duration; the video rule explicitly requests videos. Its duration/count/day rules belong to this native rule, not to the missing external generator.                                                                 |
| External Memory API              | `services/memory.service.ts`, `dtos/memory.dto.ts`, `repositories/memory.repository.ts`                    | Rule Memories contain normal asset IDs, with no photo-only constraint. Unknown external `ruleId` is retained; custom metadata and saved/viewed/rejected lifecycle remain supported.                                                                      |
| Native generation reconciliation | `services/memory.service.spec.ts`                                                                          | Existing regression preserves an unknown external `gallery_ai_highlight` with mixed photo/video IDs and does not strip its metadata/assets.                                                                                                              |
| Mobile playback                  | `presentation/widgets/memory/memory_card.widget.dart`                                                      | Video assets enter the existing `NativeVideoViewer(forceAutoPlay: true)` branch. This does not prove that the external rendered MP4 contains source-video clips.                                                                                         |

There is no proven reason here to force video quotas, reinterpret hidden Motion
Photo companions as ordinary videos, change Gallery permissions, or rerun ML
indexing/historical warmup. Smart Search's default `not-locked` visibility is
broader than Photos; external requests must explicitly choose their intended
timeline/Trash policy instead of assuming a server version number defines it.

`SmartInfoService.handleEncodeClip` also has an explicit **ordinary-video** path:
probe, sample representative frames (eight for duration ≥2 s), encode through the
existing local ML service and combine embeddings. `AssetJobRepository.streamForEncodeClip`
does not impose a photo-only type filter; hidden assets are skipped. Missing preview,
probe/frame/ML failures can leave no embedding. Existing `smart-info.service.spec.ts`
tests cover video success, duration edges, sampling and failures. This is evidence
of code support, **not** a measurement of production video embedding coverage.

## Existing VAAPI work, preserved

The task added in `30b2d01b41` records `h264_vaapi` with
`-init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va`, SDR
`format=nv12,hwupload`, successful first/last title rendering and no software
fallback on the completed July render. It also records the CPU/raw-RGB
`scale → crop → gblur → scale → overlay → fps=60` bottleneck and interrupted
process lifecycle issue. These are prior reported measurements, **not new
measurements in this cloud session**. HDR/p010 and UHD630 hardware decode/filter
composition are unproven. Gallery's `server/src/utils/media.ts` already has
backend-specific VAAPI/QSV/software transcoders, but is not that raw-frame
Memory assembler; replacing it would not fix the identified external pipeline.

No renderer replacement, new GPU backend, governor change, historical render,
production job, data mutation, or migration is authorized/performed here.
Anna/chudo_anna's album/media migration is **complete and closed**.

## Exact evidence still needed

1. Sanitised source of the actual candidate collector, eligibility rules,
   planner, JSON validator/asset resolver, `StreamingEncoder`,
   `assemble_streaming`, title renderer and subprocess cleanup/lock handling;
   their import graph/config defaults and current commit/version.
2. Current external service/container definition and image/version/module
   paths identifying where those functions run; FFmpeg build and selected
   backend/capability plan. Do not supply keys or personal paths/files.
3. One **already completed** Memory's sanitised stage counts separately for
   ordinary photo, ordinary source video and hidden Live/Motion companion:
   collected → eligible → planned → JSON accepted → resolved → rendered;
   per-stage exclusion reasons and final manifest asset types.
   Include existing-embedding/preview availability and visibility for ordinary
   source videos already in those sets; do not regenerate embeddings to obtain it.
4. That job's generated plan/validated JSON with anonymous asset IDs,
   renderer command/filter graph, stderr/fallback reason and actual output
   ffprobe summary. This localises video exclusion without making up statistics.
5. For a future small HP benchmark only: actual `vainfo`, `/dev/dri` device
   access/container limits and one chosen non-private mixed fixture workload.

Until those inputs exist, the video-defect root cause and external VAAPI
implementation/benchmark remain **BLOCKED_EXTERNAL_SOURCE**, independently of
the Android Live/Motion and CloudMediaProvider work. No production source or
runtime access was attempted.
