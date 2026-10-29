# Original Noodle Gallery API smoke report

This report is for the disposable backend only. It does not claim that an
unchanged Android or iOS client was launched.

| Field | Result |
|---|---|
| Backend source SHA | `46e013adaddeddf8d9b358bcd10b5f721270e0ed` |
| Build | **PASS** — `pnpm --dir server build` |
| Migration sync | **PASS** — 79 Gallery migrations synchronized; no stale migration remained |
| Database | **PASS** — pinned disposable PostgreSQL started on host port 5435 |
| Queue | **PASS** — pinned disposable Redis started and connected |
| Smoke command | `bash tools/original-noodle-gallery/api_smoke.sh http://127.0.0.1:2285` |
| Smoke result | **PASS** |
| Production touched | **NO** |

The smoke exercised login, auth status, album discovery, search, Trash
preflight, upload, original download, thumbnail download, Live Photo pairing,
album create/detail, full sync, incremental sync, ACK read/write/delete, Trash
restore, empty Trash, permanent delete, and reconnect/login renewal.

The first original/thumbnail requests returned transient HTTP 404 responses
while the asynchronous media processing completed. The script retried those
requests and both files were then downloaded successfully. The fixtures use a
unique media byte/comment and filename per run, so reruns remain valid after
the intentional permanent-delete reupload suppression.

The Node API worker completed startup migrations and reported no schema drift.
The PostgreSQL, Redis, and API processes were stopped and the disposable
volumes removed after the run. Official Android APK launch, unchanged-client
Android E2E, Build 22 process-death/offline replay, iOS/macOS runtime, SQLite
device replay, Shizuku runtime, and Samsung S23 checks remain separate gates.
