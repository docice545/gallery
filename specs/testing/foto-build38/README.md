# FOTO Build38 cloud evidence — work in progress

Base: `d94389c98d2ac8cbdfe3e5bcf18b3bdaac23665b`. Branch: `codex/foto-build38-unified-16`.

Actual execution on 2026-11-04 UTC / 2026-11-05 Moscow. Flutter 3.47.2 / Dart 3.13.2; Python 3.12; CPU Big-LaMa pinned by SHA-256. No HP, Samsung or iOS installation has been performed. This is not final acceptance.

## Selection and deletion

Two new regressions failed before correction: a harmless timeline reload and a server metadata timestamp update invalidated exact captured IDs. File checksum, local modification time, ownership, stack, Live Photo pair, explicit selection revision and session/route guards remain checked. Post-dispatch receipts apply only to captured IDs. Partial device removal no longer starts the aggregate success effect. Native verification/retry semantics are retained.

## Executed checks

- Python service baseline: 55 passed, 1 skipped; with the verified real model: 56 passed.
- Closed-contour regression before fix: 4 failed, 23 passed. After fix with real model: 60 passed.
- Flutter new deletion regressions before fix: 9 passed, 2 failed.
- Flutter verification: 135 passed across deletion snapshot/model guards, magic-eraser model/page and memory service. Command below.
- Existing Python mobile release tooling: 128 passed (`python3 -m unittest discover -s mobile/scripts/tests -v`). These fixture tests do not build/sign/install an IPA.
- Server memory suite: 104 passed (`pnpm --dir server test run src/services/memory.service.spec.ts`).

```sh
cd mobile
flutter test --no-pub --concurrency=2 \
  test/domain/models/deletion_snapshot_test.dart \
  test/unit/presentation/actions/deletion_snapshot_guard_test.dart \
  test/pages/edit/magic_eraser_page_test.dart \
  test/unit/domain/models/magic_eraser_test.dart \
  test/domain/services/memory_service_test.dart
```

Broader cloud regression is ongoing. The first broad action run exposed six existing album animation expectations that keep the cover stationary, contrary to the required whole-row swipe. The first editor run exposed an outdated 80dp inner-capsule assertion: the capsule is 56dp plus 24dp safe area. The corrected assertion checks the complete dock, retaining theme/viewport invariance checks. The larger editor baseline has 12 additional width assertions to review; those failures are geometry checks, not established golden-image differences. Early Flutter attempts before Pigeon completed and the first server invocation without its configured Vitest aliases were bootstrap failures, not passing tests.

## AI visual evidence

[Reviewed contact sheet](ai-closed-contour-synthetic.png) and [actual inference measurements/review notes](ai-closed-contour-report.json). Four procedural synthetic scenes, actual Big-LaMa; no private images or mock predictor. Closed contours fill both preview and service mask, including portrait/landscape coordinates. Original bytes and output dimensions were verified. Broad masking on high-frequency grass and mortar still has visible quality limitations; device photo acceptance remains required.

Reproduce from `inpainting` with the pinned local model (no download occurs in this script):

```sh
python scripts/visual_acceptance.py --model /path/to/big-lama.pt --output /new/evidence-directory
INPAINTING_TEST_MODEL=/path/to/big-lama.pt python -m pytest -q
```

## Log receipts

Raw temporary logs remain outside Git at `/workspace/foto-build38-evidence`; reproducible commands and SHA-256 receipts are retained here. CI artifact evidence will be linked after the branch checks run.

| Log | SHA-256 |
| --- | --- |
| `deletion-snapshot-red-complete.log` | `6cd6b476bb9adf14c35aea23d69f0eab0d189411b487d5f351fdf5ff3c624e4f` |
| `first-fixes-verified.log` | `fab9e37441334796cf66526e93bbd568db1fe49541dc17b9880388a9f1e367a7` |
| `inpaint-baseline.log` | `a76a3a232324b3902f12b520e4e810dfd4c7eea90dc552d7829be7cd255a5da6` |
| `inpaint-real-baseline.log` | `631374187d8fb67d6fa2449262c6b6e09e90d39fd4311713134030b9fa927d0d` |
| `inpaint-contour-red.log` | `f8460e05381bbd846ea970a07209cd9f871aafeb149c3543e8c0eb0488b9e91d` |
| `inpaint-contour-green.log` | `b4551eab0da7169f58f2b7972eb14dbbecd8dada22246b756a93c94dceb016ae` |
| `mobile-release-tools-baseline.log` | `a0a399560e31b52da3ad698f16089c8fd8c3fef96c48d4ca4a192e9d1b6dcc98` |
| `memory-server.log` | `1fb2ac95502c645a20f4c399c9bc3f6956e4d277e80909ab8e22ec91196651d4` |

## Offline feed P0

[Reproductions, reviewed renders, limitations and device gates](offline/README.md). This block remains part of the ongoing 16-task project, alongside iOS and backend acceptance.
