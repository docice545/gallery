#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
compose_file="$project_dir/docker-compose.yml"
env_file="$project_dir/.env"

die() { printf 'PRECHECK FAILED: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

need docker
need findmnt
need realpath
need ss
[[ -f "$compose_file" ]] || die "missing $compose_file"
[[ -f "$env_file" ]] || die "copy .env.example to .env first"

# shellcheck disable=SC1090
source "$env_file"

[[ "${NFS_TEST_ROOT:-}" == /mnt/gallery-nfs-test ]] || die 'NFS_TEST_ROOT must be /mnt/gallery-nfs-test'
[[ "${SSD_MEDIA_ROOT:-}" == /mnt/hp-data/gallery-nfs-test/media ]] || die 'unexpected SSD_MEDIA_ROOT'
[[ "${SSD_DB_ROOT:-}" == /mnt/hp-data/gallery-nfs-test/postgres ]] || die 'unexpected SSD_DB_ROOT'
[[ "${SSD_REDIS_ROOT:-}" == /mnt/hp-data/gallery-nfs-test/redis ]] || die 'unexpected SSD_REDIS_ROOT'
[[ "${DB_USERNAME:-}" == gallery_nfs_test ]] || die 'DB_USERNAME must be the dedicated gallery_nfs_test user'
[[ "${DB_DATABASE_NAME:-}" == gallery_nfs_test ]] || die 'DB_DATABASE_NAME must be the dedicated gallery_nfs_test database'
[[ -n "${DB_PASSWORD:-}" && "${DB_PASSWORD:-}" != replace-with-a-dedicated-alphanumeric-secret ]] || die 'set a dedicated DB_PASSWORD'
[[ "${DB_PASSWORD:-}" != *[[:space:]]* ]] || die 'DB_PASSWORD must not contain whitespace'
case "${GALLERY_SERVER_IMAGE:-}" in
  gallery-server|gallery-server:*|ghcr.io/open-noodle/gallery-server|ghcr.io/open-noodle/gallery-server:*) ;;
  *) die 'GALLERY_SERVER_IMAGE must be the local gallery-server image or ghcr.io/open-noodle/gallery-server:*' ;;
esac
[[ "${IMMICH_IGNORE_MOUNT_CHECK_ERRORS:-false}" != true ]] || die 'mount-check bypass is forbidden'

for path in "$NFS_TEST_ROOT" "$SSD_MEDIA_ROOT" "$SSD_DB_ROOT" "$SSD_REDIS_ROOT"; do
  [[ "$path" = /* ]] || die "path is not absolute: $path"
  [[ "$path" != /opt/immich* && "$path" != /mnt/hp-data/immich* ]] || die "production path: $path"
done
[[ "$SSD_MEDIA_ROOT" != "$SSD_DB_ROOT" && "$SSD_MEDIA_ROOT" != "$SSD_REDIS_ROOT" && "$SSD_DB_ROOT" != "$SSD_REDIS_ROOT" ]] || die 'SSD paths must be distinct'

[[ -d "$NFS_TEST_ROOT" ]] || die "NFS path does not exist: $NFS_TEST_ROOT"
[[ -d "$SSD_MEDIA_ROOT" && -d "$SSD_DB_ROOT" && -d "$SSD_REDIS_ROOT" ]] || die 'dedicated SSD directories must exist; preflight does not create them'
[[ "$(realpath -e "$NFS_TEST_ROOT")" == "$NFS_TEST_ROOT" ]] || die 'NFS path must not be a symlink'

mount_info=$(findmnt --mountpoint "$NFS_TEST_ROOT" --noheadings --output SOURCE,FSTYPE) || die "NFS path is not mounted: $NFS_TEST_ROOT"
read -r nfs_source nfs_type <<<"$mount_info"
[[ "$nfs_source" == '10.10.10.95:/volume1/Gallery-Test' ]] || die "unexpected NFS source: $nfs_source"
[[ "$nfs_type" == nfs || "$nfs_type" == nfs4 ]] || die "unexpected NFS filesystem: $nfs_type"
nfs_options=$(findmnt --mountpoint "$NFS_TEST_ROOT" --noheadings --output OPTIONS)
[[ ",$nfs_options," != *,ro,* ]] || die 'NFS mount is read-only; the server mount check must test the real mount'
[[ -r "$NFS_TEST_ROOT" && -x "$NFS_TEST_ROOT" ]] || die 'NFS path is not readable/searchable'

while IFS= read -r name; do
  case "$name" in
    gallery_nfs_test_server|gallery_nfs_test_postgres|gallery_nfs_test_redis) die "container name already exists: $name" ;;
  esac
done < <(docker ps -a --format '{{.Names}}')
docker network inspect gallery_nfs_test >/dev/null 2>&1 && die 'gallery_nfs_test network already exists'
ss -H -ltn '( sport = :2295 )' | grep -q . && die '127.0.0.1:2295 is already in use'

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
docker compose --project-directory "$project_dir" -f "$compose_file" config >"$rendered"
grep -q '^name: gallery-nfs-test$' "$rendered" || die 'unexpected Compose project name'
grep -q '127.0.0.1:2295:2283' "$rendered" || die 'unexpected server binding'
grep -q 'IMMICH_IGNORE_MOUNT_CHECK_ERRORS: "false"' "$rendered" || die 'mount checks are not explicitly enabled'
grep -q 'immich_default' "$rendered" && die 'production network leaked into test config'
grep -q 'immich_server\|immich_postgres\|immich_redis' "$rendered" && die 'production container name leaked into test config'
grep -q '/mnt/hp-data/immich' "$rendered" && die 'production volume leaked into test config'

printf 'PRECHECK OK: isolated project config, exact NFS source, dedicated SSD paths, names and port are clear.\n'
printf 'No container was started and no file was created or removed.\n'
