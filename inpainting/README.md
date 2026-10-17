# Optional local Magic Eraser worker

This private sidecar adds CPU inpainting without replacing or extending Gallery's existing Machine Learning container. Gallery authenticates the owner, reads the original from its storage, normalizes orientation and sends an upright full-resolution JPEG plus normalized mask strokes to this worker. The phone never uploads a server-only original back to its own server. The result is a full-resolution JPEG; the server controls preview retention and saving a normal **new** asset.

The worker has no external AI API, telemetry, model downloader or network-dependent inference. Do not expose port 3004 to the Internet. Run **exactly one Uvicorn process and one container**; replicas would bypass its global resource limit. `compose.example.yml` is an optional override for the owner's review, not an automatic deployment. If the HP Compose file uses a custom network rather than its default network, attach this new service to the server's existing private network explicitly before use.

## Model and dependencies

The selected model is Big-LaMa, an object-removal/inpainting model with an Apache-2.0 upstream implementation. It does not need Stable Diffusion, an NVIDIA GPU, a prompt or a segmentation model. The TorchScript interface was checked against [IOPaint's LaMa implementation](https://github.com/Sanster/IOPaint/blob/main/iopaint/model/lama.py): RGB float NCHW divided by 255, binary mask N1HW, RGB NCHW output, spatial padding in multiples of eight. Internal reflection padding also requires at least 16 pixels per working dimension.

The explicitly selected artifact is:

- Source: `https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt`
- Size: **205,669,692 bytes / 196.14 MiB**.
- SHA-256: `344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9`.
- Upstream repository/license: [advimman/lama](https://github.com/advimman/lama), Apache-2.0.

The default checksum is pinned and verified before `torch.jit.load`; a missing, corrupt or modified artifact makes `/health` report `ready: false`. Mount the model read-only. Models are executable artifacts: only the reviewed owner-supplied artifact should be mounted. No model weights are committed, downloaded during Docker build or downloaded by the application. Docker installs CPU-only Torch 2.10.0 from the official PyTorch CPU wheel index, plus the isolated pinned dependencies in `requirements.txt`; the existing `machine-learning/` requirements are unchanged.

## Resource policy and HP expectations

One worker decodes and infers at a time. At most three additional requests may wait, and uploads are admitted before multipart parsing. Authentication also runs before body parsing. Limits are 64 MiB per image, 36 MP, 64 strokes, 1,024 points per stroke, 8,192 points total and 75% mask coverage. Multipart input is disk-spooled, source files are copied in 256 KiB chunks, and results are file-streamed. The normal working ROI is the union of painted regions plus surrounding context, uniformly resized to at most 512 pixels on its longest side, with reflection padding. A floating-point occupancy mask preserves small marks during downscaling. Inference changes only painted source pixels, with an inward edge feather; JPEG re-encoding itself is lossy. Wide/disjoint masks may have lower effective detail than small compact selections.

The example gives this container **two CPUs, a 3 GiB memory limit, and a 1 GiB private temporary filesystem**. Confirm the HP has this headroom in addition to the existing Gallery ML/database/AI Memories workloads. A 36 MP photo adds significant decode/crop/mask memory; the compressed file size does not describe its RAM usage. The queue does not eliminate contention with unrelated processes. If available RAM is lower, reduce `INPAINTING_MAX_PIXELS` and/or `INPAINTING_WORKING_SIZE`, rather than raising concurrency. `INPAINTING_WORKING_SIZE` supports multiples of eight from 256 to 1,024; 512 is the conservative default. The environment permits at most four Torch CPU threads; the example uses two.

Verified isolated CPU smoke measurements in the Cloud environment, using two Torch threads on an AMD EPYC 7763 with five visible vCPUs, were approximately **0.88 seconds model load, 1.65 seconds for 256x256 inference, 4.57 seconds for 512x512 inference**, with approximately **640 MiB and 861 MiB peak RSS** respectively. These are **not HP i3-9100T benchmarks**. The i3 may take seconds to tens of seconds depending on working size and competing workloads; there is no measured HP latency guarantee. The default remains CPU. OpenVINO/UHD 630 acceleration is **not implemented or validated**: Big-LaMa's FFT operators and this TorchScript artifact require a verified conversion/runtime path first. There is a working CPU fallback without Intel GPU drivers.

Weights are loaded lazily and references are released after five idle minutes. Garbage collection does **not** guarantee that the Torch runtime or native allocator returns all high-water RSS to the OS. A queued request expires after 120 seconds by default. Cancellation/disconnection marks a job cancelled and discards its result; a native Torch call cannot safely be interrupted, so it retains the exclusive inference slot until it finishes. Queued cancelled requests are discarded without inference. Temporary original/results are removed after response delivery, after error/cancellation and during startup orphan cleanup.

## Private HTTP contract

Every endpoint requires `Authorization: Bearer <GALLERY_INPAINTING_TOKEN>`. Use the same random secret of at least 32 characters in the Gallery server and this worker; it must never be committed or included in commands/logs. `/opt/immich/gallery-inpainting.env` in the example is owner-created with restricted permissions. Gallery configuration remains disabled unless the owner explicitly configures its sidecar URL and secret.

- `GET /health`: `{ready, engine: "big-lama", device: "cpu", maxWorkingSize, maxPixels, active, queued}`.
- `POST /inpaint`: multipart fields `image` (upright JPEG/PNG bytes), `jobId` (UUID) and `mask` (JSON string).
- `DELETE /jobs/{jobId}`: idempotent cancellation, returning `{cancelled: boolean}`.

Mask JSON is `{ "strokes": [{ "points": [{ "x": 0.5, "y": 0.5 }], "radius": 0.04, "erase": false }] }`. Coordinates are normalized to the upright photo, and radius is relative to the shorter image dimension, from 0.001 to 0.25. Ordered additive/erasing strokes support brush selection, mask erasing, undo/redo and reset without a segmentation dependency. The server validates the same constraints before forwarding.

Success is `image/jpeg`, original upright dimensions and `Cache-Control: no-store`. Errors use 401 (auth), 409 (duplicate active ID), 413 (size), 422 (image/mask), 429 (queue full), 499 (cancelled), 503 (model unavailable) or 504 (queue wait expired). There is no original replacement, source rewrite, database access, stack modification or motion-resource editing in this container. Edited stills are ordinary new photos, not automatically claimed to be valid Live/Motion Photos.

## Local validation

From `inpainting/`, create an isolated Python 3.12 environment, install CPU Torch and test requirements, then run:

```bash
python -m pip install torch==2.10.0 --index-url https://download.pytorch.org/whl/cpu
python -m pip install -r requirements-test.txt
ruff check .
ruff format --check .
python -m pytest -q
# Optional real-model integration test; the file is explicitly supplied, never downloaded.
INPAINTING_TEST_MODEL=/absolute/path/to/verified/big-lama.pt python -m pytest -q
```

The real-model test is skipped explicitly when its environment variable is absent. It exercises the same checksum, rasterization, ROI, model, composition and JPEG pipeline, including the artifact's minimum dimensions. Mock tests cover malformed masks, thresholds, source preservation, model checksum failure, bounded admission, serial native jobs, cancel/retry, queue expiry, auth-before-body and temporary cleanup after receiver disconnection. Physical HP performance, Samsung/iPhone UX and native app builds remain separate validations.
