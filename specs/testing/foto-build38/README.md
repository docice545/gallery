# FOTO Build38 cloud evidence

Base: `d94389c98d2ac8cbdfe3e5bcf18b3bdaac23665b`. Branch: `codex/foto-build38-unified-16`.

Actual execution on 2026-11-04–05 UTC. Final candidate: `e2cc9c001d3f8efd7f1762037e16932c56699d2c`. [Complete 16-item acceptance record](../../../docs/acceptance/FOTO-Build38-unified-16.md), [visual matrix](../../../docs/acceptance/foto-visual-qa-matrix.md), [final receipts](cloud-final-receipts.json). Earlier focused results below are retained diagnostic history, not the current aggregate. Flutter 3.47.2 / Dart 3.13.2; Python 3.12; CPU Big-LaMa pinned by SHA-256. No HP, Samsung or iOS installation has been performed. This is not final acceptance.

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

The complete Flutter regression later passed **6186 tests** without changing golden baselines. Whole-row swipe expectations were corrected to require the cover to move with the title; editor assertions now distinguish the fixed image viewport from its narrower centered floating dock and preserve transform checks. Scoped provider dependencies and measured footer placement were fixed after actual failures. Full server tests passed 7028 cases, with one expected failure and twelve skips. Current build and hardware boundaries are recorded in the linked final acceptance record. Early bootstrap failures and earlier failing runs are not counted as passes.

## AI visual evidence

[Reviewed contact sheet](ai-closed-contour-synthetic.png) and [actual inference measurements/review notes](ai-closed-contour-report.json). Four procedural synthetic scenes, actual Big-LaMa; no private images or mock predictor. Closed contours fill both preview and service mask, including portrait/landscape coordinates. Original bytes and output dimensions were verified. Broad masking on high-frequency grass and mortar still has visible quality limitations; device photo acceptance remains required.

Reproduce from `inpainting` with the pinned local model (no download occurs in this script):

```sh
python scripts/visual_acceptance.py --model /path/to/big-lama.pt --output /new/evidence-directory
INPAINTING_TEST_MODEL=/path/to/big-lama.pt python -m pytest -q
```

## Log receipts

Raw temporary logs remain outside Git at `/workspace/foto-build38-evidence`; reproducible commands and SHA-256 receipts are retained here. Actual CI artifact evidence is linked in the final receipts and acceptance record.

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

[Reproductions, reviewed renders, limitations and device gates](offline/README.md). This block is included in the 16-task handoff, alongside iOS and backend. [Actual Android offline process-restart screenshots and receipt](offline-emulator/README.md) also passed and were reviewed. Physical acceptance remains required.
