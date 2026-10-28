# FOTO final RC HP handoff

This directory is a preflight/runbook only. It does not contain production
credentials, signing keys, database dumps or NAS paths with user data. Every
command below starts with read-only checks. Commands that create a backup or a
staging artifact require an explicit output path and never overwrite an
existing file.

## Read-only preflight

Run as `doctoriceadm` on HP, from a clean checkout of the published RC branch:

```bash
./scripts/release/foto-final-rc-20261028/hp-preflight.sh \
  /mnt/hp-data/codex-work/foto-integration \
  2eb2816f94647587a60c9b0e014bfdb30152fa08
```

This checks Git ancestry, worktrees, disk space, Docker daemon/container state,
the existing Build 21 APK, the signing certificate fingerprint when a public
certificate is supplied, and the presence of the compose file. It does not run
Compose, mount NAS, call a production API, or build an APK.

## Staging and artifacts

Use the existing reviewed tools only after preflight:

```bash
./scripts/release/server_build.sh <FULL_RC_SHA> /mnt/hp-data/codex-work/artifacts --check
./scripts/release/server_build.sh <FULL_RC_SHA> /mnt/hp-data/codex-work/artifacts
python3 scripts/release/android_release.py --help
```

The backend build is isolated and must use a disposable PostgreSQL/Redis/NFS
fixture. Verify migration order and rerun checks against the copy. Do not use
`/opt/immich/docker-compose.yml` for staging writes.

## Backup, switch and rollback

The reviewed repository already contains `scripts/release/gallery-install.sh`,
`gallery-upgrade.sh`, `gallery-verify.sh`, and `gallery-rollback.sh`. Run their
preflight/help modes first. A production switch requires a separate owner
approval after staging, a PostgreSQL backup and restore test, API compatibility
checks, and a recorded backend image digest. The APK must be built only after
backend verification and signed with the existing HP key; never create or
replace a signing key.

## Required HP/device evidence

Attach only redacted receipts: migration dry-run/re-run, API contract probes,
NFS fixture deletion/restore, map/geocoder samples, Magic Eraser inference,
Samsung Build 21 upgrade and Live Photo frame playback, iOS playback, and
10/100/500/1000 mixed Trash benchmarks. Keep production dumps and private
photos on HP.
