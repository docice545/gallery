# FOTO Build 22 release handoff

Published branch head: `314f65373fe9a48ee5e187b4f06b4a69de478279`.
The Memories/Big-LaMa source checkpoint is published; Web build and Chromium
acceptance passed in [run 41002023786](https://github.com/docice545/gallery/actions/runs/41002023786).
The retry-hardened exact-head compatibility receipt is
[run 41004224774](https://github.com/docice545/gallery/actions/runs/41004224774).

## What is proven

- Disposable API/backend, PostgreSQL/Redis, Android emulator, SQLite recovery
  fixture and cache policy checks have hosted receipts. Historical run
  40961734970 passed unchanged Noodle Android 5.8.0/5.9.0; run 41000215760
  reproduced a transient 5.8.0 dependency-start failure while 5.9.0 and FOTO
  Build 22 completed. Run 41004224774 is the exact-head retry.
- Build 22 debug emulator APK passes online sync, timeline rendering,
  process-death and offline relaunch.
- SQLite recovery remains copy-only: the primary/device DB is never reset,
  replaced or promoted.
- The Memories lane fix is published in `8c8905e2e` with a fixed-height
  horizontal carousel, stable portrait cards, adaptive width, edge peeks and
  widget geometry/drag coverage. The hosted command in iOS job `123884087117`
  of run `41000215760` reported `0 tests passed, 1 failed`; the test failure
  must be diagnosed before this gate can be called PASS. Pixel comparison with
  the supplied images is also open because those images were unavailable in
  the workspace.
- Big-LaMa is verified in an isolated cloud Docker build: the pinned model
  checksum, 55-worker test suite, real local inference and authenticated
  container `/inpaint` request all passed. HP staging remains a separate gate.
- The hosted Web acceptance workflow passed the production build, TypeScript and
  Svelte checks, Web Vitest suite, and a deterministic Chromium slice against a
  disposable backend. Broader authenticated media fixture coverage remains a
  separate gate.

## Signed APK status

A production-update APK is **BLOCKED in Cloud**. The old `foto` keystore is not
present in the checkout or environment, and no key was generated or copied.
The expected package/version/certificate are:

```text
package: de.opennoodle.gallery
version: 5.7.3+22
certificate SHA-256: ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18
```

The owner-run procedure is intentionally read-only until the final build and
requires the existing HP key: clean worktree and exact SHA check, Flutter
3.47.2/Java 17/toolchain check, locked codegen and tests, release build, `aapt`
package/version check, `apksigner` certificate check, SHA-256 receipt, then an
explicitly approved `adb install -r` over Build 21 using synthetic/test data.
Passwords stay local and are never passed in chat or uploaded. See
[`specs/testing/2026-10-06-mobile-week-hp-free-pilot.md`](../../specs/testing/2026-10-06-mobile-week-hp-free-pilot.md)
and [`specs/testing/2026-10-24-foto-build18-android-release.md`](../../specs/testing/2026-10-24-foto-build18-android-release.md).

## Open gates

Samsung S23/Android 16, physical iPhone/original iOS device acceptance,
read-only HP/Synology inventory, populated migration/restore/NFS benchmarks,
strict iOS test rerun (the current workflow swallows piped test failures),
production signing and any production switch remain open. Do not deploy,
migrate or alter HP/NAS/user data until the owner approves the concrete step.
