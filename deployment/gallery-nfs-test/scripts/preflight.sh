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
need jq
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

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
docker compose --project-directory "$project_dir" -f "$compose_file" config --format json >"$rendered"
jq -e '.name == "gallery-nfs-test"' "$rendered" >/dev/null || die 'unexpected Compose project name'
jq -e '
  [.services.server.ports[]? | select(.host_ip == "127.0.0.1" and (.published | tostring) == "2295" and .target == 2283)] | length == 1
' "$rendered" >/dev/null || die 'unexpected server binding'
jq -e '.services.server.environment.IMMICH_IGNORE_MOUNT_CHECK_ERRORS == "false"' "$rendered" >/dev/null || die 'mount checks are not explicitly enabled'
jq -e '[.networks[].name] | sort == ["gallery_nfs_test", "gallery_nfs_test_ingress"]' "$rendered" >/dev/null || die 'unexpected Compose networks'
jq -e '.networks.gallery_nfs_test.internal == true and .networks.gallery_nfs_test_ingress.internal != true' "$rendered" >/dev/null || die 'network isolation/ingress contract changed'
jq -e '.networks.gallery_nfs_test_ingress.driver_opts["com.docker.network.bridge.enable_ip_masquerade"] == "false"' "$rendered" >/dev/null || die 'ingress egress masquerade must be disabled'
jq -e '
  ([.services.server.networks | keys | sort] == [["gallery_nfs_test", "gallery_nfs_test_ingress"]]) and
  ([.services.database.networks | keys] == [["gallery_nfs_test"]]) and
  ([.services.redis.networks | keys] == [["gallery_nfs_test"]])
' "$rendered" >/dev/null || die 'only the API server may join the loopback-ingress network'
jq -e '
  [.services[].container_name // empty] | any(. == "immich_server" or . == "immich_postgres" or . == "immich_redis") | not
' "$rendered" >/dev/null || die 'production container name leaked into test config'
jq -e '
  [.services[].volumes[]?.source | select(startswith("/mnt/hp-data/immich") or startswith("/opt/immich"))] | length == 0
' "$rendered" >/dev/null || die 'production volume leaked into test config'

expected_names=$'gallery_nfs_test_postgres\ngallery_nfs_test_redis\ngallery_nfs_test_server'
[[ "$(docker ps -a --filter label=com.docker.compose.project=gallery-nfs-test --format '{{.Names}}' | sort)" == "$expected_names" ]] \
  || die 'existing Compose project has unexpected or missing containers'

declare -A expected_services=(
  [gallery_nfs_test_server]=server
  [gallery_nfs_test_postgres]=database
  [gallery_nfs_test_redis]=redis
)
for name in "${!expected_services[@]}"; do
  service=${expected_services[$name]}
  docker inspect "$name" | jq -e --arg service "$service" --arg project_dir "$project_dir" --arg compose_file "$compose_file" '
    .[0].Config.Labels["com.docker.compose.project"] == "gallery-nfs-test" and
    .[0].Config.Labels["com.docker.compose.service"] == $service and
    .[0].Config.Labels["com.docker.compose.oneoff"] == "False" and
    .[0].Config.Labels["com.docker.compose.project.working_dir"] == $project_dir and
    .[0].Config.Labels["com.docker.compose.project.config_files"] == $compose_file
  ' >/dev/null || die "container $name is not the expected gallery-nfs-test Compose service"
done

check_mounts() {
  local name=$1 expected=$2
  docker inspect "$name" | jq -e --argjson expected "$expected" '
    (.[0].Mounts | map({source: .Source, destination: .Destination, rw: .RW}) | sort_by(.destination)) ==
    ($expected | sort_by(.destination))
  ' >/dev/null || die "unexpected bind mounts on $name"
}
check_mounts gallery_nfs_test_server "$(jq -nc --arg media "$SSD_MEDIA_ROOT" --arg nfs "$NFS_TEST_ROOT" \
  '[{source:"/etc/localtime",destination:"/etc/localtime",rw:false},{source:$media,destination:"/data",rw:true},{source:$nfs,destination:"/data/upload",rw:true}]')"
check_mounts gallery_nfs_test_postgres "$(jq -nc --arg db "$SSD_DB_ROOT" '[{source:$db,destination:"/var/lib/postgresql/data",rw:true}]')"
check_mounts gallery_nfs_test_redis "$(jq -nc --arg redis "$SSD_REDIS_ROOT" '[{source:$redis,destination:"/data",rw:true}]')"

docker inspect gallery_nfs_test_server | jq -e '
  (.[0].HostConfig.PortBindings | keys | sort) == ["2283/tcp"] and
  .[0].HostConfig.PortBindings["2283/tcp"] == [{"HostIp":"127.0.0.1","HostPort":"2295"}]
' >/dev/null || die 'server is not bound only to 127.0.0.1:2295'

check_network() {
  local network=$1 expected=$2
  network_json=$(docker network inspect "$network" 2>/dev/null) || die "missing required network: $network"
  jq -e --arg network "$network" --argjson expected "$expected" '
    .[0] as $n |
    $n.Labels["com.docker.compose.project"] == "gallery-nfs-test" and
    $n.Labels["com.docker.compose.network"] == $network and
    ([ $n.Containers[]?.Name ] | sort) == ($expected | sort)
  ' <<<"$network_json" >/dev/null || die "unexpected containers or labels on network $network"
}
check_network gallery_nfs_test '["gallery_nfs_test_server","gallery_nfs_test_postgres","gallery_nfs_test_redis"]'
check_network gallery_nfs_test_ingress '["gallery_nfs_test_server"]'

for name in gallery_nfs_test_server gallery_nfs_test_postgres gallery_nfs_test_redis; do
  expected_networks='["gallery_nfs_test"]'
  [[ "$name" == gallery_nfs_test_server ]] && expected_networks='["gallery_nfs_test","gallery_nfs_test_ingress"]'
  docker inspect "$name" | jq -e --argjson expected "$expected_networks" '
    ([.[0].NetworkSettings.Networks | keys[]] | sort) == ($expected | sort)
  ' >/dev/null || die "unexpected network attachments on $name"
done

printf 'PRECHECK OK: existing isolated Compose project, exact NFS source, dedicated SSD paths, labels, mounts, networks and port verified.\n'
printf 'No container was started and no file was created or removed.\n'
