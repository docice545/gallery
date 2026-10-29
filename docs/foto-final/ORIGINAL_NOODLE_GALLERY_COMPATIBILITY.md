# Original Noodle Gallery compatibility gate

This gate covers unchanged Noodle Gallery Android and iOS clients. The pinned
source is `open-noodle/gallery` commit
`37aa54e632606cc6a62bc6bcbba14c62200147c4` (version 5.8.0). PR #7's required
compatibility line is present through commit
`a3d51348003b5e1fd84aa26040161f071fc4d648`.

The automated contract gate is `server/src/utils/original-noodle-gallery-contracts.spec.ts`.
It checks that login, full and incremental sync, media transfer, Live Photo
components, albums, search, Trash, restore, and permanent deletion routes remain
in the OpenAPI surface. The existing medium regression suite in
`server/test/medium/specs/sync/sync-client-compat.spec.ts` exercises the server
projection and ACK behavior against a disposable PostgreSQL database.

The disposable real-backend API smoke completed successfully in GitHub Actions
run `40866220811` at backend commit
`cb24532f35df70defa117a56685c728bb36ac122`. It covered login, auth status,
full/incremental sync and ACKs, upload/download, a Live Photo pair, album
create/detail, search, Trash restore/empty/permanent delete, and reconnect.
The same flow was then rebuilt and rerun against the current backend source
checkpoint `46e013adaddeddf8d9b358bcd10b5f721270e0ed` using disposable pinned
PostgreSQL/Redis. That exact-SHA local result is **PASS**; the hosted unchanged
client runtime result is still separate and pending. The detailed receipt is in
`docs/foto-final/ORIGINAL_NOODLE_API_SMOKE_2026-10-29.md`.

Official Android artifacts were obtained from the release URLs and inspected
with Android SDK Build Tools `35.0.0`: v5.8.0 SHA256
`385cd0734530c943bbe09f7d651434d585fbc276c2523c3c5a0357a6e94c2cd0`, and
v5.9.0 SHA256
`a00b7a4168449d5de77efb6d77294c7097721a038e8a5beff0a1a73d73ef7c9d`. Both
report package `de.opennoodle.gallery`, pass APK v2 signature verification, and
use certificate SHA256
`c1a77384cf726ba6ef0ac7ef51acd124e49941d123a2530615dd51a80c5b57c3`.

The statuses are intentionally split:

| Client | Official artifact obtained | APK/app launched | Backend API smoke | Real client E2E |
|---|---|---|---|---|
| Android 5.8.0 | **PASS** — SHA256 and v2 certificate verified | **PENDING HOSTED EMULATOR** | **PASS** — exact-SHA disposable backend smoke at `46e013adaddeddf8d9b358bcd10b5f721270e0ed` | **PENDING** |
| Android 5.9.0 | **PASS** — SHA256 and v2 certificate verified | **PENDING HOSTED EMULATOR** | **PASS** — exact-SHA disposable backend smoke at `46e013adaddeddf8d9b358bcd10b5f721270e0ed` | **PENDING** |
| iOS pinned source/TestFlight | **NOT TESTED** — no TestFlight binary is copied into the repository | **PENDING macOS simulator/TestFlight** | **CONTRACT SOURCE PASS; disposable API smoke PASS at exact backend SHA** | **NOT TESTED** |

The local worker has no Android SDK/emulator command or KVM/VMX/SVM
acceleration, so it cannot install or exercise the APKs here. The repository
workflow uses a hosted x86_64 emulator for both unchanged APKs and a macOS
runner for the iOS simulator/build checks. These are concrete runtime attempts,
not a claim that the official artifacts were unavailable.

Native Android execution is **BLOCKED LOCALLY / PENDING HOSTED** and iOS
execution is **NOT TESTED / PENDING MACOS**. The gate remains open and the
release remains **NOT RELEASE READY** until both unchanged clients complete the
workflow matrix in the JSON manifest.
