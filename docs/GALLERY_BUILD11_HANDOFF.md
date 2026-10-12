# Gallery Build 11 — resume state

Branch: `candidate/gallery-5.7.3-build11-upstream`.
Starting HEAD: `3d60f90461511659812eb1341ecda394ba9e1571`.
Production `work` remains `42790b06edc21438811e56e40c431eee37c24894`.
No production operations or real-media deletion have been performed.

## Verified basis

Official Noodle upstream: https://github.com/open-noodle/gallery, v5.7.1,
`da5480ae42b77db9cae729f2447ec9b3079ba4a7`, Immich 3.2.4.
Official v5.8.0/Immich3.3.1 is NOT integrated; its rebased history, eight migrations
and protocol changes need a separate upgrade strategy. See compatibility report.
97 upstream migration files and 371 existing API operations retained structurally.

## Implemented, combined final validation still in progress

- Additive `1794050000000-OwnerStorageDeletion`, ordinary managed owner deletion,
  explicit owner writable external mode, stable filesystem identity and existing
  descriptor/quarantine/tombstone/receipt/reference/revocation protections.
- Gallery/device/everywhere mobile modes with OS acknowledgment and partial results.
- Bounded web Live Photo autoplay and actual Chromium cold/scroll/viewer/background/
  retry/reload/album/search regressions. Mobile resume policy is being corrected.
- Compiled binary installer/upgrader/verifier/rollback entrypoints and private
  resumable signing adapter; no HP key read and no new signing key generated.
- Existing API+microservices preserved, no unrelated services/queue activation.

## Exact executed evidence available in this workspace

- Web: 6,458 passed; 2 skipped; 4 todo (full suite). TypeScript/Svelte/strict scoped
  ESLint passed; actual browser eight scenarios passed across full+targeted runs.
- Backend first full run: 6,851 passed, 2 known baseline guard failures, 1 expected
  failure, 12 skipped. Both baseline guard defects have been corrected and 40
  guard tests passed; remaining medium fixture updates/final validation pending.
- New PostgreSQL14 lifecycle/migration/revocation: 15 passed. Full official medium
  suite running; actual pinned EXIF fixtures and WASM plugin restored; affected
  30 official fixture tests passed. Do not count failed original run as PASS.
- Android binary signing guards: 33 passed, synthetic/mocked keys only.
- Installer/package/image/recovery focused checks: 115 passed so far; actual
  compiled clean-install/upgrade/rollback tests have NOT run.
- Flutter full analyze passed; first full tests running with expected stale SDK
  feature failure and known preview fixture timeout; fixture fixed (7 passed),
  regenerate Dart SDK only after full test process exits, then final full rerun.

Logs are under `/tmp/build11-*` and `/tmp/gallery-build11-*`; temporary outputs
are not release evidence. Do not repeat passed broad suites without new changes.

## Build status and next steps

Main Build11 APK/IPA/backend artifacts NOT BUILT, no release tag/package published.
Server source compile and OpenAPI/TS SDK generation passed; Dart SDK pending.
Old rollback image lacks the new Kysely migration and cannot boot upgraded DB.
A normal history-preserving fallback child retains old runtime and ONLY adds the
exact new migration and ORDER entry:
`c4c2d1991b01a372aa833a1f5ea0f9acc23be67a`, branch
`candidate/gallery-build11-hardened-rollback`.
Its existing backend artifact workflow is running:
https://github.com/docice545/gallery/actions/runs/38288841511
No main worktree/reset/rebase was used. Reuse this run, do not duplicate it.
Direct old-artifact cloud download returned403; escalation was cancelled; do not
repeat/bypass. Existing safe CI can use its own read-only Actions token.

After final source tests pass, commit combined implementation, push only candidate
branch, build unsigned iOS and Android CI validation sequentially (shared group),
and backend using reviewed fallback artifact run/source inputs. Smoke must prove
actual fallback HTTP startup+storage-mode refusal+Trash/Restore on upgraded schema.
Generate compatibility receipt ONLY from actual passing image reports. Seal all
main application artifacts to one exact source SHA, assemble complete distribution,
run real isolated installer/upgrade/interruption/rollback acceptance, publish tag
and immutable checksums only with honest test/physical gate labels.

## Hard gates

Actual restored production database, HP NFS, S23/iPhone acceptance, owner HP-key
signing, SideStore signing, and production deployment are NOT executed here.
The six previously confirmed jobs must be reconciled through the exact existing
native sealed handler or verified completed receipts. Preserve all21other paused
jobs. Paused HP queue means expiration activation remains separately gated.
Never invent source/proof/rollback PASS, enable old FileDelete jobs, remount NAS,
change production PostgreSQL or touch VPN/DNS/Memories infrastructure.

Verdict at this checkpoint: NOT READY. Continue implementation and artifacts;
this document is a recovery record, not a request to stop.
