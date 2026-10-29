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
| 5 | SQLite corruption recovery | SOURCE PASS / DEVICE NOT TESTED | Startup health guard added; recovery fixtures and device replay remain |
| 6 | Android CloudMediaProvider | SOURCE PASS / DEVICE NOT TESTED | Existing provider sources; Samsung/Photo Picker runtime remains |
| 7 | Shizuku admission | SOURCE PASS / DEVICE NOT TESTED | Existing admission policy; real Shizuku permission cycle remains |
| 8 | Samsung Gallery compatibility | NOT TESTED | Requires Galaxy S23 / One UI |
| 9 | System Photo Picker | NOT TESTED | Requires Android system provider selection |
| 10 | MediaStore/SAF/Share | NOT TESTED | Requires Android runtime |
| 11 | Android Live Photo | SOURCE PASS / DEVICE NOT TESTED | Existing tests; device codecs and paired playback remain |
| 12 | iOS Live Photo | SOURCE PASS / DEVICE NOT TESTED | Requires macOS/iOS runtime |
| 13 | Web Live Photo | PASS (source tests) | Chromium media E2E remains in CI/fixture scope |
| 14 | Places | SOURCE PASS / DEVICE NOT TESTED | Device map rendering remains |
| 15 | Russian geodata | SOURCE PASS / DEVICE NOT TESTED | Localized geocoder/device rendering remains |
| 16 | Editor | SOURCE PASS / DEVICE NOT TESTED | Compact editor source and tests present; installed APK route remains |
| 17 | Magic Eraser | SOURCE PASS / HP NOT TESTED | Big-LaMa service and authenticated HP inference remain |
| 18 | Android Trash | SOURCE PASS / DEVICE NOT TESTED | Device MediaStore confirmation remains |
| 19 | Stack deletion | SOURCE PASS | Existing stack-trash regression suite |
| 20 | `chudo_anna` duplicates | BLOCKED | Requires read-only HP/NAS inventory |
| 21 | All-owner duplicates | BLOCKED | Requires read-only HP/NAS inventory |
| 22 | Empty Trash performance | SOURCE PASS / HP NOT TESTED | Disposable PG/NFS benchmark remains |
| 23 | External Library/NAS | BLOCKED | Requires disposable NFS and HP topology |
| 24 | Managed Assets | SOURCE PASS / HP NOT TESTED | HP storage validation remains |
| 25 | Albums/Faces/Memories | SOURCE PASS | Existing API and sync regressions |
| 26 | Original Noodle compatibility | API PASS / ANDROID CI PENDING / iOS NOT TESTED | APKs obtained and signed; hosted emulator workflow added |
| 27 | PostgreSQL | SOURCE PASS / DISPOSABLE RUN PENDING | Migration and populated upgrade need disposable PG |
| 28 | Backend Docker | SOURCE CONFIG PASS / BUILD PENDING | Disposable image build requires CI registry availability |
| 29 | Web build | NOT TESTED | Run docs/web build in CI |
| 30 | APK build/signing | NOT TESTED | Production key remains HP-only; no unsigned APK is release-ready |
| 31 | Backup/rollback | SOURCE PASS / HP NOT TESTED | HP snapshot and restore test required |
| 32 | Real Samsung/iOS E2E | BLOCKED | Physical devices and macOS runner required |
| 33 | Final production switch gates | NOT RELEASE READY | Owner-approved HP staging and all mandatory runtime gates remain |

The machine-readable client gate is
`server/test/contracts/original-noodle-gallery-compatibility.json`. It records
the official Android artifact hashes and signing certificate, the pinned source
commit, PR #7 integration evidence, and the explicit native runtime statuses.
