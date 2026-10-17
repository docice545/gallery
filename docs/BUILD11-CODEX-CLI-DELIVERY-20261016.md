# Gallery release delivery record — 2026-10-16

Source commit: `69249fcaca1c4ea6cbd7d145f26b935da1d06722`
Branch: `codex/nas-release-readiness-20261016`
PR: https://github.com/docice545/gallery/pull/1 (open, draft)

This record covers local, isolated build evidence only. No production Compose,
NAS, VPN, real user media, or production database was accessed or changed.

| Deliverable | Result | Evidence |
| --- | --- | --- |
| Backend Docker image | **DONE locally** | `gallery-server:trash-69249fcaca1c`, image ID/digest `sha256:e763a66e91e809028cf92f7214620f23cbb7ee7690e97e725c587bfdea255ae0`, `linux/amd64` |
| Backend export | **DONE locally** | `/mnt/hp-data/codex-work/gallery-auto/20261016-103548-3633719/backend-artifact-69249/gallery-server-linux-amd64.tar.gz`, SHA-256 `fa54a79d9bbdbb6cd6e50dc58ca7e172ef9da8d1ddf89b9ed79ac315b79ad123` |
| Web frontend | **DONE locally** | `BUILD11_web_build.log` and `BUILD11_web_lint.log` |
| Android APK | **DONE locally, debug only** | `/mnt/hp-data/codex-work/gallery-auto/20261016-092107-3580683/artifacts/gallery-debug.apk`, version `5.7.3-DEBUG`, code `11`, SHA-256 `9cca50c1b0b6975cdc53c351206327dce618ea2d4d805f0a8a23390290308d15` |
| Registry/GitHub artifact publication | **BLOCKED** | CLI has no authenticated `gh`/registry credentials |

The backend build used `scripts/release/server_build.sh`, which builds from a
clean archived commit, stamps server version `5.7.3`, verifies source provenance,
checks compiled migrations, runs an isolated network-disabled container smoke,
and exports the image. Release-smoke unit tests: 60 passed; install/android
release tests: 53 passed. The Android repository, guard, and synthetic scale
tests are recorded in `specs/testing/2026-10-16-codex-local-android-build.md`.

The complete 1/10/100/1000 deletion matrix, real Synology/NFS validation,
full storage integration/e2e suite, release-signed APK, and registry upload
remain pending. Existing synthetic tests do not establish real-NAS behavior.
Deployment remains **NOT_DEPLOYED**.
