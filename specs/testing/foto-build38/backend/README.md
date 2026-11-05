# Disposable backend validation

The actual artifact built from `2d8567bfd4235c1ee58d83390ab635ce544fb295` passed [GitHub run 41983664223](https://github.com/docice545/gallery/actions/runs/41983664223) on 2026-11-05. It also passed the same real HTTP lab on the cloud workspace's local Docker daemon. The local entry point now requires explicit `--local-disposable-lab`; no CI environment impersonation is used. **35 Python contract tests PASS** validate the runner, provenance, consent and failure handling.

Validated against fresh disposable PostgreSQL/Redis and compiled API + microservices: fresh migrations; version 5.7.3; authenticated original HEAD/length; upload; Trash/Restore idempotency, exact original bytes and dates; generated preview/thumbnail files and HTTP viewing; owner consent/revocation; durable permanent-deletion receipts; reimport suppression; an actual external-library scan, default read-only gate and owner-authorized physical deletion; diagnostic read-only SQL/Redis path.

The earlier external-scan failure was a fixture error: its directory was inside managed `/data`, which the server correctly rejects. Only the synthetic fixture was moved to `/tmp/gallery-build38-external-ci`; the production protection is unchanged. A subsequent CI attempt hit GHCR rate limiting. The successful rerun executed every HTTP assertion; neither failure was counted as a pass.

The local command accepts an immutable artifact directory and full source SHA, never a server URL, existing DB, production media path or container name. It forces the local Unix Docker socket, creates random uniquely named containers/network, binds only a new temporary read-only lab trust directory, and exposes the API on a random **127.0.0.1** port. Cleanup removes only containers successfully created by that invocation, with their anonymous volumes. Existing services, images, media, credentials and autostack processes are not used. Synthetic recovery receipts prove only verifier contracts and never certify production backups.

```sh
# After checking the downloaded artifact SHA-256 and immutable source receipt:
docker --host=unix:///var/run/docker.sock load -i /path/to/artifact/gallery-server-linux-amd64.tar.gz
python3 scripts/release/server_artifact_smoke.py --local-disposable-lab \
  FULL_ARTIFACT_SOURCE_SHA /path/to/artifact
```

`receipts.json` contains immutable artifact identities and actual log hashes. The artifact is held by GitHub Actions; the Docker archive and raw logs are not committed. This is not production deployment, HP validation, a restore drill, a NFS permission test, or a rollback pass. Those remain **HP_REQUIRED**. Final acceptance must select the final reviewed source artifact; this earlier successful build remains diagnostic evidence.
