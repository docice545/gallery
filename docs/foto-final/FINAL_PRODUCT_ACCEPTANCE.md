# FOTO final product acceptance matrix

This matrix records evidence for the integrated release candidate. `PASS` means
the named automated or source check ran; `BLOCKED` identifies a missing HP,
macOS, Samsung, iOS, or CI runtime; `NOT TESTED` means no claim is made.

| # | Gate | Status | Evidence / remaining blocker |
|---:|---|---|---|
| 1 | Git integration | PASS | Master-final branch created from published RC; push and SHA verification pending for this checkpoint |
| 2 | Offline catalogue | PASS | Existing offline source line and regression receipts in RC |
| 3 | Thumbnail warmup | PASS | Existing mobile tests and RC receipts |
| 4 | Wi-Fi/cellular | PASS | Existing network preference tests |
| 5 | `SCREENSHOT_THUMBNAIL_FRAMING` | SOURCE FIX / CI + APK PENDING | Edge-content contain framing and rendered-pixel fixture; hosted Flutter/APK/Samsung evidence required |
| 6 | `OFFLINE_GRAY_SCREEN_RECOVERY` | SOURCE FIX / CI + APK PENDING | Versioned durable cache, auth/DNS fallback, corrupt-entry removal; hosted Android offline process-death evidence required |
| 7 | SQLite corruption recovery | SOURCE PASS / DEVICE NOT TESTED | Startup health guard added; recovery fixtures and device replay remain |
| 8 | Android CloudMediaProvider | SOURCE PASS / DEVICE NOT TESTED | Existing provider sources; Samsung/Photo Picker runtime remains |
| 9 | Shizuku admission | SOURCE PASS / DEVICE NOT TESTED | Existing admission policy; real Shizuku permission cycle remains |
| 10 | Samsung Gallery compatibility | NOT TESTED | Requires Galaxy S23 / One UI |
| 11 | System Photo Picker | NOT TESTED | Requires Android system provider selection |
| 12 | MediaStore/SAF/Share | NOT TESTED | Requires Android runtime |
| 13 | Android Live Photo | SOURCE PASS / DEVICE NOT TESTED | Existing tests; device codecs and paired playback remain |
| 14 | iOS Live Photo | SOURCE PASS / DEVICE NOT TESTED | Requires macOS/iOS runtime |
| 15 | Web Live Photo | PASS (source tests) | Chromium media E2E remains in CI/fixture scope |
| 16 | Places | SOURCE PASS / DEVICE NOT TESTED | Device map rendering remains |
| 17 | Russian geodata | SOURCE PASS / DEVICE NOT TESTED | Localized geocoder/device rendering remains |
| 18 | Editor | SOURCE PASS / DEVICE NOT TESTED | Compact editor source and tests present; installed APK route remains |
| 19 | Magic Eraser | SOURCE PASS / HP NOT TESTED | Big-LaMa service and authenticated HP inference remain |
| 20 | Android Trash | SOURCE PASS / DEVICE NOT TESTED | Device MediaStore confirmation remains |
| 21 | Stack deletion | SOURCE PASS | Existing stack-trash regression suite |
| 22 | `chudo_anna` duplicates | BLOCKED | Requires read-only HP/NAS inventory |
| 23 | All-owner duplicates | BLOCKED | Requires read-only HP/NAS inventory |
| 24 | Empty Trash performance | SOURCE PASS / HP NOT TESTED | Disposable PG/NFS benchmark remains |
| 25 | External Library/NAS | BLOCKED | Requires disposable NFS and HP topology |
| 26 | Managed Assets | SOURCE PASS / HP NOT TESTED | HP storage validation remains |
| 27 | Albums/Faces/Memories | SOURCE PASS | Existing API and sync regressions |
| 28 | Original Noodle compatibility | API PASS / ANDROID CI PENDING / iOS NOT TESTED | APKs obtained and signed; hosted emulator workflow added |
| 29 | PostgreSQL | SOURCE PASS / DISPOSABLE RUN PENDING | Migration and populated upgrade need disposable PG |
| 30 | Backend Docker | SOURCE CONFIG PASS / BUILD PENDING | Disposable image build requires CI registry availability |
| 31 | Web build | NOT TESTED | Run docs/web build in CI |
| 32 | APK build/signing | NOT TESTED | Production key remains HP-only; no unsigned APK is release-ready |
| 33 | Backup/rollback | SOURCE PASS / HP NOT TESTED | HP snapshot and restore test required |
| 34 | Real Samsung/iOS E2E | BLOCKED | Physical devices and macOS runner required |
| 35 | Final production switch gates | NOT RELEASE READY | Owner-approved HP staging and all mandatory runtime gates remain |

The machine-readable client gate is
`server/test/contracts/original-noodle-gallery-compatibility.json`. It records
the official Android artifact hashes and signing certificate, the pinned source
commit, PR #7 integration evidence, and the explicit native runtime statuses.
