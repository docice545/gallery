# Codex task: Immich Memories VAAPI/render pipeline optimization

Target branch: `work`.

## Context

This repository is being prepared as the Noodle Gallery fork. Incorporate the Immich Memories rendering optimization into that work. Do not touch production VPN/AWG/DNS configuration.

Production hardware used for validation: Intel Core i3-9100T with Intel UHD 630.

## Verified production findings

- Final July Memories render successfully selected `h264_vaapi`.
- Real production FFmpeg was verified with:
  `-init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va`
  and the filter ending in `format=nv12,hwupload`, with `-c:v h264_vaapi -compression_level 4`.
- Automatic fallback to `libx264` no longer occurred after the runtime StreamingEncoder patch.
- First/last title background pre-render also succeeded once VAAPI device context and SDR hwupload were supplied.
- Isolated `StreamingEncoder` test and real `assemble_streaming()` test both passed with `h264_vaapi` and no fallback.
- During a real render the VAAPI encoder was mostly starved. CPU preprocessing was the bottleneck. The per-clip path included:
  `scale -> crop -> gblur -> scale -> overlay -> fps=60`
  and emitted RGB/raw frames.
- A preprocessing FFmpeg consumed about 88% CPU while the VAAPI encoder consumed about 16%; `intel_gpu_top` showed the Video engine mostly idle and RC6 around 98-100%.
- CPU governor was `intel_pstate powersave` with EPP `balance_performance`; observed cores were approximately 2.1/2.5/2.9/3.3 GHz. A performance governor may help CPU preprocessing but must be benchmarked, not assumed.
- Qwen/OpenVINO on UHD 630 is out of scope/closed. Qwen2.5-VL GPU tests failed with OpenCL `CL_OUT_OF_RESOURCES` / kernel issues. Keep Ollama/Qwen on CPU.
- HDR is NOT yet proven. A runtime experiment contemplated `p010le,hwupload`, but HDR must be explicitly tested before support is claimed.

## Required work

1. Inspect branch `work` and the current Noodle Gallery fork architecture before changing code.
2. Implement VAAPI handling cleanly and backend-aware. Do not globally hardcode VAAPI behavior for software/NVENC/QSV paths.
3. Ensure `StreamingEncoder` receives the required VAAPI device/filter context and SDR upload format while preserving safe software fallback.
4. Apply the same backend-aware principle to title first/last rendering. Replace any unconditional VAAPI runtime-style behavior with plan/capability-based behavior.
5. Investigate eliminating or reducing the CPU/raw-RGB bottleneck. Prefer keeping frames in FFmpeg/iGPU surfaces where practical: hardware scale/format/upload and, if feasible on UHD 630, hardware composition/filtering. Preserve visual output and transitions; do not sacrifice correctness just to move filters to GPU.
6. Benchmark before/after on representative 1920x1080@60 Memories assembly. Report wall time, CPU use, encoder choice/fallback, and Intel Video/Render engine utilization.
7. Evaluate an optional job-scoped CPU performance policy only if benchmark proves useful. Do not permanently force the whole host into performance mode.
8. Add tests for SDR `h264_vaapi`, software fallback, non-VAAPI backend unaffected, title first/last, interrupted encoder, and HDR separately.
9. Test HEVC VAAPI/p010 HDR explicitly. If UHD 630/driver does not support the required encode path, fail/fallback cleanly and document it rather than pretending HDR acceleration works.
10. Keep changes isolated to Gallery/Memories integration. Do not change host VPN, AWG, Xray, AdGuard Home, routing, firewall, or DNS.
11. Keep commits focused and provide a concise benchmark/test report before proposing merge to `main`.

## Process lifecycle issue found in production

A prior transient systemd + `docker exec` render left a live child process after the transient unit disappeared. Do not rely solely on systemd unit visibility for concurrency.

Pipeline locking uses `fcntl.flock` on `.lock`; automation uses a separate `.auto.lock`. Interrupted renders must clean up child FFmpeg processes so orphan workers do not continue consuming CPU or leave pipeline state inconsistent.

## Acceptance criteria

- Real SDR final assembly uses `h264_vaapi` without software fallback on UHD 630.
- No regression for software or non-VAAPI paths.
- Title pre-render works.
- Interrupted jobs clean up child FFmpeg processes.
- Any adopted preprocessing optimization shows a measurable improvement.
- HDR behavior is explicitly tested and accurately reported.
- No production infrastructure/network changes.
