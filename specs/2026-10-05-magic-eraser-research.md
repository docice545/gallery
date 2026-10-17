# Local inpainting for Photos on the HP server

Research date: 2026-10-05. Target: Intel Core i3-9100T, Intel UHD 630, no NVIDIA GPU. This is a model and deployment decision record; it does not claim a production benchmark or a working UHD 630 acceleration path.

## Existing Gallery architecture

Gallery already has a Flutter editor (`mobile/lib/presentation/pages/edit/`), server edit instructions (`server/src/services/asset.service.ts`, `asset-edit.repository.ts`, `utils/editor.ts`) and a Sharp-based image pipeline. Existing edits are geometric/non-destructive transformations and video trimming. They provide navigation, authenticated asset access and image decoding/orientation machinery, but there was no brush-mask inpainting or point-prompt segmentation pipeline in the starting branch.

The separate `machine-learning/` application is FastAPI with ONNX Runtime, local model caching/unloading and CPU/OpenVINO execution-provider selection. Its registered tasks are search, facial recognition, OCR and pet detection/recognition. Face/pet boxes are not arbitrary-object pixel masks. Adding PyTorch to that existing process would enlarge its dependency footprint and compete with its current inference workers. A separate optional, private inpainting worker keeps those tasks and the external AI Memories/auto-stack systems intact. Gallery continues to authorize the asset and obtain the server-storage original; the phone sends strokes/edit instructions rather than downloading and uploading a server-only original.

## Model comparison

| Option | Quality/implementation | CPU and iGPU considerations | License and decision |
| --- | --- | --- | --- |
| LaMa / Big-LaMa | Fourier convolution model designed for large irregular masks and repeated background structure. One forward pass; no prompt or diffusion sampler. LaMa's official repository demonstrates CPU prediction. | Practical CPU baseline. Fourier transforms require explicit conversion validation before an OpenVINO implementation can be trusted. Resolution/region limits are necessary on this HP. | Original LaMa repository: Apache-2.0, copyright Samsung Research. Selected Big-LaMa inference-only TorchScript export. |
| MAT | Mask-aware transformer; upstream reports strong large-hole benchmark quality. | Upstream stack assumes CUDA/PyTorch and includes StyleGAN-derived machinery. It is not a demonstrated lightweight CPU/OpenVINO package for this HP. | Upstream explicitly says code and models are for research purposes only. Not selected for the product. |
| GMCNN (`gmcnn-places2-tf`) | Older inpainting network with an actual Intel Open Model Zoo conversion and image-inpainting demo. Open Model Zoo uses 512×680 image/mask inputs. | Official demo accepts CPU or GPU; a genuine alternative if measured on the HP. This says nothing about its relative quality or latency on the HP until compared. Published source archive: 46,187,310 bytes. | MIT model implementation, Apache-2.0 Intel tooling. Lower-priority alternative: legacy TensorFlow conversion/dependency path and older model quality. Not installed. |
| Stable Diffusion inpainting | Prompt-conditioned generative editing, substantially broader than object removal. | Multi-step diffusion, larger model/runtime/activation footprint. Not a justified default for an i3/UHD 630 appliance sharing resources with Gallery. | Model-specific licenses vary; no diffusion dependency or checkpoint introduced. |

LaMa can hallucinate incorrect structure or fail on very large masks, faces, fine lettering and complicated geometry. A before/after preview and explicit save-copy decision are essential. This is object removal, not a guarantee of reconstructing the true hidden scene.

## Selected artifact and provenance

The selected inference artifact is the Big-LaMa TorchScript model used by the established IOPaint LaMa adapter:

```text
URL:    https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt
Bytes:  205669692
Size:   196.14 MiB (205.67 MB decimal)
SHA256: 344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9
MD5:    e3aa4aaa15225a33ec84f9f4bc47e500
```

The file was downloaded through the managed cloud proxy and hashed locally. Its MD5 matches the IOPaint adapter's published value. The SHA-256 above is computed from the actual file, not inferred from a download filename. Model bytes are not committed to Git. Installation downloads the public model once; inference must not make outgoing network requests or transmit photos to the model publisher.

The TorchScript archive was inspected before loading: it contains the expected `saicinpainting`/Torch convolution, tensor and Fourier-transform graph; no Python URL fetching, shell execution, external library loading or arbitrary custom inference operators were found in its serialized source. Its entry point takes RGB float `NCHW` plus a binary `N1HW` mask and composites the original image outside the mask. LaMa conventions use white/1 for the region to replace; MAT's documented mask convention differs and must not be reused accidentally. Input padding is a multiple of eight.

The original LaMa release repository is Apache-2.0; IOPaint is also Apache-2.0. The selected third-party release has no separate model card or contradictory use restriction visible in the inspected release material. Preserve the original license and attribution when distributing the model/service. The checksum identifies the trusted derivative; it is not an independent license grant. MAT's explicit research-only statement prevents treating all inpainting checkpoints as interchangeable permissive assets.

## Resource envelope and HP speed

Weights alone occupy about 195 MiB in the inspected archive. The full process also needs the CPU Torch runtime, intermediate activations, original/result raster buffers and image decoding; checkpoint size is not a RAM estimate. Start with one active inference, two CPU threads, a bounded model input around 512 pixels, strict original decoded-pixel limits and a finite processing timeout. A 3 GiB worker memory budget is the initial configuration, not a measured minimum: multiple full-resolution 36MP image/mask buffers can coexist with the model/runtime, so the 512-pixel inference benchmark alone does not bound total memory. Use measured peak RSS for the final HP limit and leave memory for PostgreSQL, Gallery ML and other workloads.

Prefer a context region around the mask over feeding a full multi-megapixel original to the model. Keep the original full-size image on the server and composite only the selected region back into a static copy. Resizing the context necessarily limits detail in the repaired region; the surrounding unmasked raster should remain unchanged before the final image encoding. Full-size inpainting and refinement would be much more expensive and are not the safe initial default for this machine.

The isolated worker is one process. It imports Torch and loads model weights lazily, then after 300 seconds idle releases model references and calls garbage collection. This does not terminate an inference child: Torch runtime and allocator high-water memory may remain in the process RSS. Complete idle-memory release would require a separately implemented process-recycling strategy. A single-process worker/global queue is required; starting multiple web workers or multiple replicas defeats a process-local semaphore unless protected by a common job lock. A busy response/queue state must remain visible to the mobile client. Canceling a running request must not release the concurrency slot while its heavy native computation continues.

The actual selected artifact passed a CPU smoke with Torch 2.10.0 and two inference threads on the cloud AMD EPYC 7763 environment (five assigned vCPUs). Model load took 0.881 seconds. Synthetic inference results were:

| Input region | Model inference | Process peak RSS |
| --- | --- | --- |
| 256×256 | 1.651 seconds | 640.3 MiB |
| 512×512 | 4.565 seconds | 860.6 MiB |

The smoke asserted output shape, finite values, changed pixels inside the mask and exact preservation outside the mask. These times omit the Gallery network/storage round trip and full-resolution image decoding/encoding. They do not benchmark i3-9100T/UHD 630 or establish output quality on real unwanted objects.

There is no i3-9100T/UHD 630 benchmark in this cloud environment. For planning, allow seconds to tens of seconds for a bounded 512-pixel context on CPU, potentially longer under concurrent workloads/thermal throttling; this is a rough expectation, not a measured HP speed or service guarantee. Expect a user-visible asynchronous processing delay, not live brush-stroke inference. Measure cold-load time, warm model inference, JPEG/HEIC decoding/encoding, end-to-end latency and peak RSS on the HP with representative small/large masks before enabling the feature for routine use. Record both CPU-only behavior and impact on existing ML/AI Memories jobs. No iGPU speedup is promised.

## OpenVINO and Intel UHD 630

OpenVINO's published system requirements include 6th–14th-generation Intel Core processors and Intel UHD Graphics. Intel's compute-runtime documentation places Coffee Lake/Gen9 hardware in its **legacy1** driver packages; its regular modern packages have supported Gen12 and later since release 24.35.30872.22. Thus copying a current Arc/Xe driver recipe to UHD 630 is not a verified deployment plan.

The selected artifact contains `torch.fft_rfftn`, `torch.fft_irfftn` and complex-valued operations. A successful model conversion, equivalent RGB/mask preprocessing, matching output comparison and actual device compilation are all necessary. Merely installing `onnxruntime-openvino`, mounting `/dev/dri`, or observing a GPU device does not establish model support or an acceleration benefit. Existing Gallery ML's OpenVINO provider does not execute this new TorchScript model automatically.

The CPU implementation is the dependable initial path. OpenVINO CPU/iGPU remains a researched optimization, not an advertised implemented backend. The clean private image+mask interface permits a future validated OpenVINO worker without changing the mobile workflow or the existing Gallery ML image. The Intel GMCNN demo is evidence of a real OpenVINO inpainting option, but is not evidence that Big-LaMa has already been converted or benchmarked. No OpenVINO, GPU driver or production device permissions were installed/changed by this research.

## Optional tap-to-select segmentation

Manual brush/erase, undo/redo and zoom are sufficient for the first release and avoid another always-resident AI model.

**MobileSAM** is the most practical model to investigate next: a point/box-prompt SAM-compatible decoder with a much smaller Tiny-ViT encoder. Upstream reports 9.66 million parameters for the full encoder+decoder and a CPU demo (~3 seconds on its own Mac i5). That is approximately 39 MB of FP32 parameter data before packaging, and is not an i3-9100T speed or total-memory claim. Its repository is Apache-2.0. A server implementation can compute one embedding on demand, accept tap prompts in the same normalized image coordinates, let the user correct the resulting mask with the brush, and expire the embedding after the editing session. Do not implement an automatic background segmentation library mirror.

**SAM 2.1 tiny** is another Apache-2.0 option with explicitly licensed checkpoints, but 38.9 million parameters and video-oriented features are unnecessary for this initial still-photo workflow. Full SAM ViT-H (~615 million parameters) is a poor fit compared with MobileSAM. No segmentation checkpoint, dependency or misleading enabled button is introduced by the first brush-only version.

## Still copies and live-photo limits

Inpainting changes still pixels. It cannot silently claim that an unchanged paired video matches the altered still image. A result is therefore a normal independent static Gallery image; the original and its Live/Motion relationship remain untouched. In particular, do not copy Samsung's embedded-video metadata/trailer into the new JPEG or attach the original Apple paired video to it. Original date/timezone/owner can be carried into the normal asset ingestion path without carrying format-specific motion pairing identifiers. The new save-copy API must not assign a stack or erase existing manual stack/unstack choices. Existing external production auto-stack scripts remain untouched: they can subsequently group same-capture-date copies according to their own rules, so this feature does not claim to suppress that external grouping. Any automatic policy for excluding AI-edited copies must be integrated separately using their provenance, while preserving manual decisions. Restore/replace-original UI is not appropriate unless the complete existing edit and rollback pipeline can store this AI result safely; explicit save-copy is the first-release behavior.

## Primary sources

1. [LaMa README, CPU inference and training/model details](https://github.com/advimman/lama/blob/786f5936b27fb3dacd2b1ad799e4de968ea697e7/README.md) and [Apache-2.0 license](https://github.com/advimman/lama/blob/786f5936b27fb3dacd2b1ad799e4de968ea697e7/LICENSE).
2. [IOPaint LaMa adapter, artifact URL and published MD5](https://github.com/Sanster/IOPaint/blob/61a759fb3f332bacdce8b2813f4837495c9b86e0/iopaint/model/lama.py), [IOPaint license](https://github.com/Sanster/IOPaint/blob/61a759fb3f332bacdce8b2813f4837495c9b86e0/LICENSE), and [Big-LaMa release asset](https://github.com/Sanster/models/releases/tag/add_big_lama).
3. [MAT README, dependencies and research-only terms](https://github.com/fenglinglwb/MAT/blob/d273d891ecdad2e1df106516423a75bc45b2d800/README.md).
4. [Intel GMCNN model, shape/conversion/license](https://github.com/openvinotoolkit/open_model_zoo/blob/master/models/public/gmcnn-places2-tf/README.md), [download manifest](https://github.com/openvinotoolkit/open_model_zoo/blob/master/models/public/gmcnn-places2-tf/model.yml), and [CPU/GPU inpainting demo](https://github.com/openvinotoolkit/open_model_zoo/blob/master/demos/image_inpainting_demo/python/README.md).
5. [OpenVINO 2024.6 system requirements](https://github.com/openvinotoolkit/openvino/blob/2024.6.0/docs/articles_en/about-openvino/release-notes-openvino/system-requirements.rst).
6. [Intel compute-runtime legacy Gen9 support](https://github.com/intel/compute-runtime/blob/d4fc0756006fa28738766cb66034dc9acadea91e/documentation/LEGACY_PLATFORMS.md) and [device access requirements](https://github.com/intel/compute-runtime/blob/d4fc0756006fa28738766cb66034dc9acadea91e/README.md).
7. [MobileSAM README, parameter counts and CPU demo](https://github.com/ChaoningZhang/MobileSAM/blob/f706ad9c4eb7f219c00d9050e46328518ffb65d2/README.md) and [license](https://github.com/ChaoningZhang/MobileSAM/blob/f706ad9c4eb7f219c00d9050e46328518ffb65d2/LICENSE).
8. [SAM 2 README, tiny-model size and checkpoint license](https://github.com/facebookresearch/sam2/blob/main/README.md).

All source retrieval and the selected artifact download used the managed network policy. No private photos were sent to an external service. A Hugging Face ONNX export was found in third-party references, but that host is outside this environment's allowlist and its artifact/license could not be independently validated here; it is not the selected dependency.
