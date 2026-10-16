# Gallery NFS integration stand

This directory describes the isolated `gallery-nfs-test` Compose project. It is
configuration and test tooling only; it does not start containers, mount NFS, or
delete files by itself.

## Isolation contract

| Boundary | Test value | Production value | Protection |
| --- | --- | --- | --- |
| Compose project | `gallery-nfs-test` | `immich` | fixed Compose `name` |
| Server container | `gallery_nfs_test_server` | `immich_server` | preflight rejects existing name and rendered production names |
| PostgreSQL container/data | `gallery_nfs_test_postgres`, dedicated SSD path | `immich_postgres` and its data | separate bind path; no host port |
| Redis container/data | `gallery_nfs_test_redis`, dedicated SSD path | `immich_redis` and its data | separate bind path; no host port |
| Docker network | `gallery_nfs_test` (internal) | `immich_default` | fixed private network; preflight rejects production network text |
| HTTP | `127.0.0.1:2295` only | production ports | Compose binds only loopback |
| NFS | `/mnt/gallery-nfs-test` from `10.10.10.95:/volume1/Gallery-Test` | family/NAS originals | preflight requires the exact source and path |

The server receives the dedicated SSD media root at `/data`. Only `/data/upload`
is overlaid with the exact test NFS bind mount. Gallery therefore writes uploaded
JPG originals to NFS while extracted Motion/Live MP4 files, thumbnails, encoded
video and profiles remain on the dedicated SSD. PostgreSQL and Redis never use
NFS. The single server container explicitly runs both the API and microservices
workers, so metadata extraction and deletion jobs are processed inside this
isolated project. The ML service is intentionally omitted and disabled for this
focused test.

`IMMICH_IGNORE_MOUNT_CHECK_ERRORS` is explicitly `false`; the normal mount-file
read/write checks remain active. The NFS mount itself must be present before the
server is started.

## Gates and non-destructive preparation

1. Copy `.env.example` to `.env`, choose the image under test, set a unique DB
   password, and create the three empty dedicated SSD directories as the owner.
   Preflight requires the dedicated `gallery_nfs_test` PostgreSQL user/database
   and rejects the template password. Compose passes only the listed test
   settings to the server; it does not import an arbitrary production env file.
2. Run `scripts/preflight.sh`. It is read-only apart from Docker's config
   rendering and refuses symlinks, production paths, stale test names/network,
   port conflicts, a wrong NFS export, and any mount-check bypass.
3. Do not run Compose from production (`/opt/immich`) and do not use production
   `.env`, databases, Redis, networks or volumes.
4. `scripts/run-live-photo-test.sh` requires an explicit
   `GALLERY_NFS_TEST_CONFIRM=I_UNDERSTAND_SYNTHETIC_ONLY` gate before it starts
   the stand. It requires the separate
   `GALLERY_NFS_TEST_PURGE_CONFIRM=I_UNDERSTAND_PERMANENT_PURGE` gate immediately
   before the second delete and final trash empty. The script has no automatic
   `down`, cleanup, reset, or path-wide deletion.

No command in this preparation stage runs GitHub Actions, paid services, a
production container, VPN/NAS configuration, or a migration.

## Verification matrix

The gated script records a database row and physical file check after every
phase. It uploads one synthetic JPEG containing a synthetic H.264 MP4, waits for
metadata extraction and the `livePhotoVideoId` relation, and verifies:

- the image row points under `/data/upload` and its bytes exist at
  `/mnt/gallery-nfs-test`;
- the linked video row points under `/data/encoded-video` and its bytes exist on
  the dedicated SSD;
- first delete sets `deletedAt` for the still while both originals remain;
- restore clears the deletion state and preserves the relation;
- second delete, owner-scoped managed consent, and the authenticated trash-empty
  operation remove the test rows and both originals only after its separate purge
  gate. The script calls `GET /trash/empty/preflight` immediately before the
  destructive request and requires exactly one authorized `managed` scope.

The script also repeats the read-only state query after a failed/partial HTTP
operation. A retry is allowed only for the same synthetic asset ID; it never
searches or retries against an arbitrary library path. If NFS becomes
unavailable, the script stops, captures `findmnt`, Docker health and database
state, and leaves all evidence in place for manual recovery. It does not turn a
partial failure into a destructive retry.
