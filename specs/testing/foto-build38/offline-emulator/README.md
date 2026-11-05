# Actual Android offline process-restart evidence

[Online](online.png) and [offline after force-stop/relaunch](offline.png) are unmodified, visually reviewed Android API 35 x86_64 emulator captures. [Run 41992098090, attempt 2](https://github.com/docice545/gallery/actions/runs/41992098090/attempts/2) succeeded. The first attempt failed when the emulator disappeared from ADB; its cause is not established and that failure remains in the final receipts.

The debug APK was built from PR merge `d5d9cf90acc04479f329edb75229dae40cecbfda`, incorporating candidate `e2cc9c001d3f8efd7f1762037e16932c56699d2c` into `b216af2be0dd5867c45221724f9612afff62abb8`. It is distinct from the candidate's unsigned release APK. Exact APK, artifact, log and image hashes are in [receipt.json](receipt.json).

The real app loaded two synthetic server photos, was force-stopped, had network disabled, and reopened offline. The actual test reported decoded marker counts `[6400, 4560]` in both captures. Review confirms both January 2024 and January 2020 groups remain in place; the Timeline rectangle `(0,80)–(320,550)` is pixel-identical. The white regions are part of the deliberately simple source images, not grey placeholders. The account connection indicator changes offline. These are synthetic fixture images, not private photos.

This scenario verifies previously cached server images after offline process restart. It does not test year dragging, a large library, local-only cold start or reconnect; those have separate [Flutter regressions](../offline/README.md). Samsung, final signed APK upgrade and real photographic rendering remain **DEVICE_REQUIRED**. No installation acceptance is inferred from a debug AVD run.

Reproduce using the existing `original-noodle-gallery-compatibility.yml` workflow and its `FOTO Build 22 offline timeline emulator E2E` job. The historical job/artifact name does not change the tested source. Do not run the fixture's data-clearing setup on the user's phone.
