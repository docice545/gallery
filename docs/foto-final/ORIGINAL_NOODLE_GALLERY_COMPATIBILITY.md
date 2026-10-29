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
run `40864366678` at backend commit
`4c123818fc03cc7f4ca434f12ae41dade047b4c6`. It covered login, auth status,
full/incremental sync and ACKs, upload/download, a Live Photo pair, album
create/detail, search, Trash restore/empty/permanent delete, and reconnect.

Official Android artifacts were obtained from the release URLs and inspected
with Android SDK Build Tools `35.0.0`: v5.8.0 SHA256
`385cd0734530c943bbe09f7d651434d585fbc276c2523c3c5a0357a6e94c2cd0`, and
v5.9.0 SHA256
`a00b7a4168449d5de77efb6d77294c7097721a038e8a5beff0a1a73d73ef7c9d`. Both
report package `de.opennoodle.gallery`, pass APK v2 signature verification, and
use certificate SHA256
`c1a77384cf726ba6ef0ac7ef51acd124e49941d123a2530615dd51a80c5b57c3`.

The Android emulator image was installed, but this worker has no KVM/VMX/SVM
acceleration (`x86_64 emulation currently requires hardware acceleration`), so
the APKs could not be installed or exercised in an emulator. No macOS host is
available for the iOS TestFlight/simulator path. These are the specific runtime
blockers; they do not invalidate the downloaded artifact or API contract tests.

Native Android and iOS execution is **BLOCKED / NOT TESTED** in this Cloud
session. The gate remains blocked and the release remains **NOT RELEASE READY**
until both unchanged clients complete the workflow matrix in the JSON manifest.
