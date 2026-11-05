# Real inpainting Docker HTTP smoke

Built the existing CPU Dockerfile at candidate `e2cc9c001d3f8efd7f1762037e16932c56699d2c` with CA trust supplied only as a BuildKit secret. Real local container, read-only root/model, one worker, 2 CPU / 3 GiB limit, temporary files on tmpfs, random loopback-only port, private generated test token. No user photos, production endpoints or model download.

Actual **PASS**: unauthorized health returns 401; the checksum-pinned Big-LaMa is ready; closed-mask HTTP inference returns JPEG 480×320 with `no-store`; original is unchanged; unknown cancellation is idempotent; working files are removed. [Receipt](receipt.json) includes actual wall time and image/model hashes. The container was removed after the test.

Reviewed [synthetic source](synthetic-before.png) and [actual response](synthetic-after.jpg): the red object is removed from a smooth gradient. This simple scene is a container integration check, not a replacement for the more difficult [four-scene quality review](../ai-closed-contour-report.json) or real-photo acceptance.

Reproduce with the standard-library-only `docs/acceptance/inpainting-docker-check.py --image sha256:ACTUAL_64_HEX_IMAGE_ID --model /path/to/existing/big-lama.pt --output /new/private/evidence`. It refuses an unpinned image, wrong model checksum or existing output directory, performs no registry pull, and removes only its own newly created container. HP performance/real-photo quality remain **HP_REQUIRED / DEVICE_REQUIRED**.
