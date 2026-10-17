#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
compose=(docker compose --project-directory "$project_dir" -f "$project_dir/docker-compose.yml")
api='http://127.0.0.1:2295/api'

die() { printf 'TEST STOPPED: %s\n' "$*" >&2; exit 1; }
[[ "${GALLERY_NFS_TEST_CONFIRM:-}" == I_UNDERSTAND_SYNTHETIC_ONLY ]] || die 'set GALLERY_NFS_TEST_CONFIRM=I_UNDERSTAND_SYNTHETIC_ONLY'

"$script_dir/preflight.sh"
# shellcheck disable=SC1091
source "$project_dir/.env"
fixture_dir=$(mktemp -d "$SSD_MEDIA_ROOT/fixture.XXXXXX")
fixture_still="$fixture_dir/synthetic-live-photo.jpg"
fixture_video="$fixture_dir/synthetic-motion.mp4"
fixture_upload="$fixture_dir/synthetic-live-photo-upload.jpg"
credentials_file="$fixture_dir/credentials.env"
run_nonce="$(date +%s%N)-$RANDOM"
on_error() {
  status=$?
  printf 'Diagnostics retained in %s (status %s):\n' "$fixture_dir" "$status" >&2
  findmnt --mountpoint "$NFS_TEST_ROOT" --output TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 >&2 || true
  "${compose[@]}" ps 2>&1 >&2 || true
  if [[ -n "${asset_id:-}" ]]; then state 2>&1 >&2 || true; fi
  exit "$status"
}
trap on_error ERR

for command in curl ffmpeg exiftool jq openssl; do
  command -v "$command" >/dev/null 2>&1 || die "missing $command"
done

printf 'Starting only the isolated project after both confirmation gates.\n'
"${compose[@]}" up -d --wait --wait-timeout 180

password="${GALLERY_NFS_TEST_PASSWORD:-$(openssl rand -hex 24)}"
email="${GALLERY_NFS_TEST_EMAIL:-gallery-nfs-test-$(date +%s)@example.invalid}"
printf 'EMAIL=%q\nPASSWORD=%q\n' "$email" "$password" >"$credentials_file"
curl_json() { curl --fail --silent --show-error "$@"; }

if [[ "${GALLERY_NFS_TEST_REUSE_ACCOUNT:-false}" != true ]]; then
  curl_json -X POST "$api/auth/admin-sign-up" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg e "$email" --arg p "$password" '{email:$e,password:$p,name:"Synthetic NFS test"}')" >/dev/null
fi
token=$(curl_json -X POST "$api/auth/login" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg e "$email" --arg p "$password" '{email:$e,password:$p}')" | jq -r '.accessToken')
[[ -n "$token" && "$token" != null ]] || die 'login did not return a token'
auth=(-H "Authorization: Bearer $token")

ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=blue:s=640x480:d=1 -frames:v 1 -q:v 2 "$fixture_still"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=green:s=640x480:d=1.2 -an -c:v libx264 -pix_fmt yuv420p \
  -metadata comment="Gallery synthetic NFS motion ${run_nonce}" "$fixture_video"
motion_size=$(stat -c '%s' "$fixture_video")
exiftool -overwrite_original \
  -XMP-dc:Description="Gallery synthetic NFS lifecycle ${run_nonce}" \
  -XMP-GCamera:MotionPhoto=1 -XMP-GCamera:MotionPhotoVersion=1 \
  -XMP-GCamera:MicroVideo=1 -XMP-GCamera:MicroVideoVersion=1 \
  -XMP-GCamera:MicroVideoOffset="$motion_size" "$fixture_still" >/dev/null
cat "$fixture_still" "$fixture_video" >"$fixture_upload"

upload_json=$(curl_json -X POST "$api/assets" "${auth[@]}" \
  -F "assetData=@$fixture_upload;type=image/jpeg" \
  -F 'fileCreatedAt=2026-10-16T20:00:00.000Z' \
  -F 'fileModifiedAt=2026-10-16T20:00:00.000Z')
asset_id=$(jq -r '.id' <<<"$upload_json")
[[ "$asset_id" =~ ^[0-9a-f-]{36}$ ]] || die 'upload did not return an asset id'

db() { "${compose[@]}" exec -T database psql -U "$DB_USERNAME" -d "$DB_DATABASE_NAME" -At -F $'\t' -c "$1"; }
state() {
  db "SELECT id, \"originalPath\", \"livePhotoVideoId\", \"deletedAt\" FROM asset WHERE id = '$asset_id' OR id = (SELECT \"livePhotoVideoId\" FROM asset WHERE id = '$asset_id') ORDER BY id;"
}
wait_for_pair() {
  for _ in $(seq 1 90); do
    motion=$(db "SELECT \"livePhotoVideoId\" FROM asset WHERE id = '$asset_id';")
    if [[ "$motion" =~ ^[0-9a-f-]{36}$ ]]; then return 0; fi
    sleep 2
  done
  state
  die 'metadata extraction did not produce a linked motion asset'
}
assert_files() {
  mount_info=$(findmnt --mountpoint "$NFS_TEST_ROOT" --noheadings --output SOURCE,FSTYPE) || die "NFS mount disappeared: $NFS_TEST_ROOT"
  read -r source filesystem <<<"$mount_info"
  [[ "$source" == '10.10.10.95:/volume1/Gallery-Test' ]] || die "NFS source changed during test: $source"
  [[ "$filesystem" == nfs || "$filesystem" == nfs4 ]] || die "NFS filesystem changed during test: $filesystem"
  [[ -s "$NFS_TEST_ROOT/${still_path#/data/upload/}" ]] || die 'uploaded JPG is absent from the test NFS'
  [[ -s "$SSD_MEDIA_ROOT/${motion_path#/data/}" ]] || die 'extracted MP4 is absent from dedicated SSD'
}
wait_for_pair
printf 'STATE uploaded-and-linked:\n%s\n' "$(state)"
still_path=$(db "SELECT \"originalPath\" FROM asset WHERE id = '$asset_id';")
motion_id=$(db "SELECT \"livePhotoVideoId\" FROM asset WHERE id = '$asset_id';")
motion_path=$(db "SELECT \"originalPath\" FROM asset WHERE id = '$motion_id';")
[[ "$still_path" == /data/upload/* ]] || die "still is not under /data/upload: $still_path"
[[ "$motion_path" == /data/encoded-video/* ]] || die "motion is not under /data/encoded-video: $motion_path"
assert_files

# A failed read is a safe partial-operation probe. The following state snapshot
# must be byte-for-byte identical, proving a retry does not widen its scope.
before_failed_read=$(state)
missing_asset_code=$(curl -sS -o "$fixture_dir/missing-asset-response.json" -w '%{http_code}' "${auth[@]}" "$api/assets/00000000-0000-4000-8000-000000000000")
[[ "$missing_asset_code" == 400 ]] || die "unexpected status for missing-asset probe: $missing_asset_code"
jq -e '.message == "Not found or no asset.read access"' "$fixture_dir/missing-asset-response.json" >/dev/null || die 'missing-asset probe did not return the expected safe access error'
after_failed_read=$(state)
[[ "$before_failed_read" == "$after_failed_read" ]] || die 'failed probe changed database state'

curl_json -X DELETE "$api/assets" "${auth[@]}" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg id "$asset_id" '{ids:[$id]}')" >/dev/null
printf 'STATE first-trash:\n%s\n' "$(state)"
first_deleted=$(db "SELECT \"deletedAt\" IS NOT NULL FROM asset WHERE id = '$asset_id';")
[[ "$first_deleted" == t ]] || die 'first delete did not move the still to trash'
assert_files

curl_json -X POST "$api/trash/restore/assets" "${auth[@]}" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg id "$asset_id" '{ids:[$id]}')" >/dev/null
printf 'STATE restored:\n%s\n' "$(state)"
restored_deleted=$(db "SELECT \"deletedAt\" IS NULL FROM asset WHERE id = '$asset_id';")
[[ "$restored_deleted" == t ]] || die 'restore did not clear the still deletion state'
assert_files
# A repeated restore is an idempotent retry of the same synthetic operation.
before_restore_retry=$(state)
curl_json -X POST "$api/trash/restore/assets" "${auth[@]}" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg id "$asset_id" '{ids:[$id]}')" >/dev/null
after_restore_retry=$(state)
[[ "$before_restore_retry" == "$after_restore_retry" ]] || die 'repeated restore changed database state'

[[ "${GALLERY_NFS_TEST_PURGE_CONFIRM:-}" == I_UNDERSTAND_PERMANENT_PURGE ]] || die 'set GALLERY_NFS_TEST_PURGE_CONFIRM=I_UNDERSTAND_PERMANENT_PURGE before the second delete and final purge'
curl_json -X DELETE "$api/assets" "${auth[@]}" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg id "$asset_id" '{ids:[$id]}')" >/dev/null
printf 'STATE second-trash-before-purge:\n%s\n' "$(state)"
# Explicitly authorize only this owner’s managed roots in the isolated test DB.
# This is separate from the purge confirmation and never touches production policy.
curl_json -X PUT "$api/assets/managed-deletion-consent" "${auth[@]}" -H 'Content-Type: application/json' \
  --data '{"enabled":true,"confirmed":true}' >/dev/null
purge_preflight=$(curl_json "$api/trash/empty/preflight" "${auth[@]}")
[[ "$(jq -r 'length' <<<"$purge_preflight")" == 1 ]] || die 'unexpected trash purge scope count'
[[ "$(jq -r '.[0].scope' <<<"$purge_preflight")" == managed ]] || die 'unexpected trash purge scope'
[[ "$(jq -r '.[0].authorized' <<<"$purge_preflight")" == true ]] || die 'managed trash purge is not authorized'
curl_json -X POST "$api/trash/empty" "${auth[@]}" >/dev/null
for _ in $(seq 1 90); do
  final_state=$(db "SELECT count(*) FROM asset WHERE id = '$asset_id' OR id = '$motion_id';")
  if [[ "$final_state" == 0 && ! -e "$NFS_TEST_ROOT/${still_path#/data/upload/}" && ! -e "$SSD_MEDIA_ROOT/${motion_path#/data/}" ]]; then
    break
  fi
  sleep 2
done
[[ "$final_state" == 0 ]] || die 'final purge did not remove the two synthetic asset rows'
[[ ! -e "$NFS_TEST_ROOT/${still_path#/data/upload/}" ]] || die 'JPG still exists on NFS after final purge'
[[ ! -e "$SSD_MEDIA_ROOT/${motion_path#/data/}" ]] || die 'MP4 still exists on SSD after final purge'
printf 'PASS: synthetic Live Photo lifecycle and physical NFS/SSD placement. Evidence: %s\n' "$fixture_dir"
