# FOTO parallel client release gates

| Gate | Status | Evidence / blocker |
|---|---|---|
| Published base and independent branch | **PASS** | `codex/foto-final-rc-20261028` at `4bd351510bba8750f0f54d8777523d6603a44fdd`; acceptance branch contains audit docs only |
| Build 21 provenance compared | **PASS** | Build 21 `57b79cf3a7f11960ead971ca8963d666cc6baa91` is a different line and misses the final-RC client commits listed in the audit |
| Offline catalogue / persistent previews | **PASS (source/tests)** | 71 Flutter tests and 91 Android JVM tests; Samsung cold-start/airplane-mode/old-year scroll **BLOCKED** |
| Wi-Fi/cellular prefetch consent | **PASS (source/tests)** | Policy and consent tests; real settings route, warning, traffic behavior on Samsung **BLOCKED** |
| Android local/remote Live Photo | **PASS (source/tests)** | Local, remote pair, merged local component, no-cascade and lifecycle tests; decoded frames on Samsung **BLOCKED** |
| Web one-active Live Photo | **PASS (source/tests/build)** | 49 targeted tests, Svelte diagnostics, lint, format and production build pass; real Chromium media **NOT TESTED** |
| Places and Russian names | **SOURCE PRESENT** | Place policy JVM coverage; production geodata/native tiles/Samsung rendering **BLOCKED** |
| Four-tool editor and Magic Eraser | **SOURCE PRESENT** | Source is already four-tool at both compared SHAs; installed APK route and Samsung/HP inpainting **BLOCKED** |
| Whole-tree Flutter analyze | **BLOCKED** | Generated OpenAPI tests and Drift migration fixtures are incomplete/incompatible in this checkout; scoped tracked-source analysis passes |
| Unmodified Noodle Gallery Android compatibility | **NOT TESTED** | Requires fixed upstream APK, test account and disposable backend |
| Unmodified Noodle Gallery iOS compatibility | **NOT TESTED** | Requires iOS device/app and disposable backend |
| Backend/DB/NAS/migrations | **NOT TESTED** | HP/disposable staging unavailable; no production changes made |
| APK version/signature/update over Build 21 | **NOT TESTED** | No APK build/install/signing key in Cloud; verify on HP with `versionCode > 21` |
| Release readiness | **NOT RELEASE READY** | Physical, provenance, upstream-client, whole-tree generated-fixture and HP gates remain open |
