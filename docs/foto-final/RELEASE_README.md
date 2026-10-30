# FOTO Build 22 release handoff

Last remote source checkpoint: `aa15c6ce9b20fb65abf4534c21bf154777970d8c`. Local final handoff: `f087c5fef4918058d20fdb89660bee51c4e63896` (push blocked by unavailable GitHub proxy).
The tested code checkpoint is `d9b64f1a15d5582f08fa5b9f8fd24c5062a5a552`.
Hosted acceptance run: [40961734970](https://github.com/docice545/gallery/actions/runs/40961734970).

## What is proven

- Disposable API/backend, PostgreSQL/Redis, Android emulator, iOS simulator,
  SQLite recovery fixture, cache policy tests, and unchanged Noodle Android
  5.8.0/5.9.0 E2E pass on the final source checkpoint.
- Build 22 debug emulator APK passes online sync, timeline rendering,
  process-death and offline relaunch.
- SQLite recovery remains copy-only: the primary/device DB is never reset,
  replaced or promoted.

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
Web final build/browser E2E, production signing and any production switch remain
open. Do not deploy, migrate or alter HP/NAS/user data until the owner approves
the concrete step.
