# Gallery build 8: frozen artifacts and HP handoff

**BLOCKED for the expanded deletion contract.** See the
[acceptance matrix](GALLERY_BUILD8_ACCEPTANCE.md). Integrity/preflight PASS is
not approval or device acceptance. No deployment, merge, signing or retention is
authorized. The following operational commands describe later approved gates.

Frozen application: `6a558b554e26e8c0fc5bc5c99259a92e7ef26a56`.
Production `work`: `42790b06edc21438811e56e40c431eee37c24894`, unchanged.
Server 5.7.1; Android/iOS 5.7.2 (8). This tooling introduces no migration.

## Immutable artifacts

| Component | Download                                                                                                                                               | File SHA-256                                                       | Status                                       |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------ | -------------------------------------------- |
| Backend   | [37953392247 / 11626603468](https://github.com/docice545/gallery/actions/runs/37953392247/artifacts/11626603468), `gallery-trash-server-linux-amd64`   | `29679cf72b40eea7513addd26979771a4b4ebba9fb5106926d87ee2c05395194` | Built/tested; not deployed                   |
| Android   | [37944044747 / 11624073289](https://github.com/docice545/gallery/actions/runs/37944044747/artifacts/11624073289), `android-media-pilot-validation-apk` | `ae3ed08bfe8794e1f12193e5d29733c22c22e7671672726e1a27b869483a4527` | CI debug-signed; cannot update HP-signed app |
| iOS       | [37936380827 / 11618922989](https://github.com/docice545/gallery/actions/runs/37936380827/artifacts/11618922989), `ios-unsigned-ipa`                   | `4abfdbd7007c5f72d85fbb2cc8b35c20891c7342d2c9e6cba85c23792278a6bd` | Unsigned; SideStore signing required         |

Backend config digest remains
`sha256:fecdc0aa17477cdfef901dc32097b852f7f2ca94befeca4c2ea43ca16d6c8b3c`.
HP reported `sha256:a442828f7bf4d4aebd6673b4e3b14cc91039e503d6625c623e1a38864761ce14`.
The latter is not trusted without the new descriptor/config/layer proof.
The proof workflow reuses these binaries, tests classic/containerd stores and
packages them with SHA256SUMS, machine manifest and tooling; no recompilation.
Its manifest records the acceptance blocker, not a production-ready claim.

## A. Artifact verification and fresh recovery preparation

Run as doctoriceadm. Download `trash_predeploy.py` **and** companion
`trash_image_identity.py` from the full commit/checksums in the final handoff;
keep them in one new private directory. Keep the original pinned release tool
at `/home/doctoriceadm/gallery-trash-release-tooling-565ef38/trash_release.py`.
Set `GALLERY_STAGE1_TOOL` to the new checksum-verified wrapper:

```bash
(
  set -euo pipefail
  : "${GALLERY_STAGE1_TOOL:?Verified new wrapper path required}"
  python3 -B "$GALLERY_STAGE1_TOOL" verify-image \
    --artifacts /home/doctoriceadm/gallery-trash-frozen-artifacts
  python3 -B "$GALLERY_STAGE1_TOOL" prepare \
    --artifacts /home/doctoriceadm/gallery-trash-frozen-artifacts \
    --pinned-tool /home/doctoriceadm/gallery-trash-release-tooling-565ef38/trash_release.py
)
```

Verification exports an already loaded image by immutable ID, streams hashes and
stores only a private proof. It never loads/tags/pulls. Preparation always uses a
**new** 0700 state, creates a fresh consistent SQL/gzip backup and verifies that
exact hash by isolated restore with no production mounts/ports/network. NAS PASS
is reused at its genuine original timestamp; 24-hour expiry remains STOP. Old
PG receipts do not validate a fresh dump. Preserve all old recovery/failed states,
including `gallery-predeploy-klailu49` and `gallery-predeploy-j37jutgt`.

Set `GALLERY_STAGE1_STATE` to the new PASS directory printed above:

```bash
(
  set -euo pipefail
  : "${GALLERY_STAGE1_TOOL:?}" "${GALLERY_STAGE1_STATE:?}"
  python3 -B "$GALLERY_STAGE1_TOOL" recheck --state "$GALLERY_STAGE1_STATE"
)
```

PASS requires source/artifact/config/topology identity, healthy four containers,
verified PG identity, matching compiled/live migrations, backup under one hour,
its exact restore, NAS under 24 hours, rollback image/disk/config and atomic zero
counts in seven deletion states plus complete unresolved-job inventory. Unknown,
nonzero, stale or changed state is STOP. SCAN alone never proves empty.

## B. Future backend-only deployment and recovery

Only after separate owner approval and resolution of application blockers. The
admin variable names an existing private 0600 key file, never the key itself:

```bash
(
  set -euo pipefail
  [[ "${GALLERY_DEPLOYMENT_APPROVED:-}" == YES ]]
  : "${GALLERY_STAGE1_TOOL:?}" "${GALLERY_STAGE1_STATE:?}" "${GALLERY_STAGE1_ADMIN_KEY:?}"
  python3 -B "$GALLERY_STAGE1_TOOL" deploy --state "$GALLERY_STAGE1_STATE" \
    --key "$GALLERY_STAGE1_ADMIN_KEY" --approve-deployment
)
```

It rechecks and proves the image, backs up Compose/.env/old image, journals before
pausing backgroundTask, then recreates only immich-server API-only by immutable
image ID. It requires paused-empty queues and never clears/drains/retries them.
Health checks require ping, 5.7.1, exact source, migrations and unchanged PG/Redis/ML
IDs. VPN/DNS/routing/proxies are never accessed. A journal means **do not retry
deploy** after failure. Use the same journal and separately approved rollback:

```bash
(
  set -euo pipefail
  [[ "${GALLERY_DEPLOYMENT_APPROVED:-}" == YES ]]
  : "${GALLERY_STAGE1_TOOL:?}" "${GALLERY_STAGE1_STATE:?}" "${GALLERY_STAGE1_ADMIN_KEY:?}"
  python3 -B "$GALLERY_STAGE1_TOOL" rollback --state "$GALLERY_STAGE1_STATE" \
    --key "$GALLERY_STAGE1_ADMIN_KEY" --approve-deployment
)
```

Rollback checks the candidate proof/journal, external config interference,
previous image/archive and other IDs; only the server changes. Workers remain
API-only and deletion paused. It does not restore DB/NAS or reverse physical
deletion. Missing/mismatched rollback prerequisites mean STOP/manual review.

Approved disposable smoke uses `acceptance` with the same state/key/approval
flags. It uploads only a unique synthetic PNG, verifies Trash/Restore bytes,
dates and idempotency, rejects duplicate upload before deletion and leaves it
active. The full device/video/Live matrix is still required. Worker enablement
also requires `--approve-retention` and
`GALLERY_RETENTION_RESUME_APPROVED=YES`; no enablement is authorized here.

## C. Future Android signing

Current production checkout at 42790b06 cannot pass the existing signer: it
requires clean `work` at exactly the frozen source. First approve integration
separately; do not relax this guard. A new deletion candidate needs new affected
artifacts and pins. For the unchanged payload only, after separate signing approval:

```bash
(
  set -euo pipefail
  [[ "${GALLERY_SIGNING_APPROVED:-}" == YES ]]
  : "${JAVA_HOME:?Existing JDK 17}" "${ANDROID_HOME:?Existing SDK}"
  python3 /home/doctoriceadm/gallery-trash-release-tooling-565ef38/android_release.py \
    sign-existing --repository /opt/gallery-fork \
    --expected-head 6a558b554e26e8c0fc5bc5c99259a92e7ef26a56 --build-number 8 \
    --input-apk /home/doctoriceadm/gallery-trash-frozen-artifacts/android/app-release.apk \
    --authorize-production-signing
)
```

Existing key.jks/alias foto is used without replacement. Input CI hash, package,
version, certificate, unchanged non-signature payload and alignment are checked.
Output must have certificate
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`:
`/opt/gallery-fork/mobile/build/release-handoff/android-5.7.2-8-6a558b554e26/Foto.apk`.
The signer writes checksum/release metadata. Use an in-place signed update;
never uninstall or install the CI-debug APK to bypass signature mismatch.

## D. iPhone

Use the linked IPA and existing SideStore + LocalDevVPN route. Reuse the same
Personal Team, append-team setting and App Group/ShareMedia mapping on updates.
Use existing `mobile/scripts/release/prepare_sidestore.py` only if the existing
pilot needs its deterministic seed transformation; no new IDs or signing service.
See [the existing runbook](RELEASE_RUNBOOK.md).

Choose **Keep App Extensions → Register App ID for Each Extension**, not Main
Profile or Remove Extensions. SideStore signs; unsigned is not installable.
Verify Фото, 5.7.2 (8), update without uninstall, session/data, App Group,
ShareExtension (iOS 16+), WidgetExtension (iOS 17+), Live pairs and background
sync. Runner stays iOS 15. Free provisioning expires after seven days; preserve
the established refresh/LocalDevVPN setup and test renewal physically.
