#!/usr/bin/env bash
set -euo pipefail

base_url=${1:?base URL is required}
base=${base_url%/}/api
workdir=${TMPDIR:-/tmp}/noodle-api-smoke
mkdir -p "$workdir"
stage=preflight
stage_code() {
  case "$1" in
    preflight) echo 71 ;; login) echo 72 ;; discovery) echo 73 ;;
    media_generation) echo 74 ;; upload) echo 75 ;; downloads) echo 76 ;;
    albums) echo 77 ;; sync) echo 78 ;; acks_and_trash) echo 79 ;;
    reconnect) echo 80 ;; *) echo 70 ;;
  esac
}
trap 'status=$?; code=$(stage_code "$stage"); printf "%s\n%s\n%s\n" "$stage" "$status" "$BASH_COMMAND" > "$workdir/failure.txt"; echo "API smoke failed at stage $stage (line $LINENO): $BASH_COMMAND" >&2; exit "$code"' ERR
mark_stage() { stage=$1; printf '%s\n' "$stage" > "$workdir/stage.txt"; }
mark_stage preflight
command -v curl jq ffmpeg convert >/dev/null

mark_stage login
json_header=(-H 'content-type: application/json')
login_json=$(curl --fail --silent --show-error -X POST "$base/auth/login" "${json_header[@]}" \
  -d '{"email":"admin@immich.cloud","password":"password"}')
token=$(jq -er '.accessToken' <<<"$login_json")
auth=(-H "Authorization: Bearer $token")

mark_stage discovery
curl --fail --silent --show-error "$base/auth/status" "${auth[@]}" >/dev/null
curl --fail --silent --show-error "$base/albums" "${auth[@]}" >/dev/null
curl --fail --silent --show-error "$base/search/explore" "${auth[@]}" >/dev/null
curl --fail --silent --show-error "$base/trash/empty/preflight" "${auth[@]}" >/dev/null
echo 'API smoke: auth and discovery passed'

mark_stage media_generation
convert -size 32x32 xc:'rgb(32,96,160)' -quality 85 "$workdir/noodle-still.jpg"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=16x16:d=1 \
  -vf format=yuv420p -c:v libx264 -movflags +faststart -y "$workdir/noodle-motion.mp4"

upload_asset() {
  local file=$1 filename=$2 extra_field=${3:-} response
  if [[ -n "$extra_field" ]]; then
    response=$(curl --fail --silent --show-error -X POST "$base/assets" "${auth[@]}" \
      -F "assetData=@$file" -F "filename=$filename" \
      -F 'fileCreatedAt=2024-01-01T00:00:00.000Z' -F 'fileModifiedAt=2024-01-01T00:00:00.000Z' \
      -F "$extra_field")
  else
    response=$(curl --fail --silent --show-error -X POST "$base/assets" "${auth[@]}" \
      -F "assetData=@$file" -F "filename=$filename" \
      -F 'fileCreatedAt=2024-01-01T00:00:00.000Z' -F 'fileModifiedAt=2024-01-01T00:00:00.000Z')
  fi
  jq -e '.status == "created" and (.id | type == "string")' <<<"$response" >/dev/null
  jq -er '.id' <<<"$response"
}

mark_stage upload
video_id=$(upload_asset "$workdir/noodle-motion.mp4" 'noodle-motion.mp4')
still_id=$(upload_asset "$workdir/noodle-still.jpg" 'noodle-still.jpg' "livePhotoVideoId=$video_id")
echo 'API smoke: upload and Live Photo pair passed'
mark_stage downloads
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error "$base/assets/$still_id" "${auth[@]}" >/dev/null && \
     curl --fail --silent --show-error "$base/assets/$still_id/original?download=true" "${auth[@]}" -o "$workdir/original.jpg"; then
    break
  fi
  sleep 2
done
test -s "$workdir/original.jpg"

for _ in $(seq 1 30); do
  if curl --fail --silent --show-error "$base/assets/$still_id/thumbnail?size=preview" "${auth[@]}" -o "$workdir/thumbnail.jpg"; then
    break
  fi
  sleep 2
done
test -s "$workdir/thumbnail.jpg"
echo 'API smoke: original and thumbnail downloads passed'

mark_stage albums
album_json=$(curl --fail --silent --show-error -X POST "$base/albums" "${auth[@]}" "${json_header[@]}" \
  -d "{\"albumName\":\"Noodle compatibility smoke\",\"assetIds\":[\"$still_id\"]}")
album_id=$(jq -er '.id' <<<"$album_json")
curl --fail --silent --show-error "$base/albums/$album_id" "${auth[@]}" >/dev/null
echo 'API smoke: album operations passed'

mark_stage sync
sync_body='{"types":["UsersV1","AssetsV2","AlbumsV2"],"reset":true}'
curl --fail --silent --show-error -X POST "$base/sync/stream" "${auth[@]}" "${json_header[@]}" \
  -d "$sync_body" -o "$workdir/sync-full.jsonl"
grep -q 'SyncCompleteV1' "$workdir/sync-full.jsonl"

sync_body='{"types":["UsersV1","AssetsV2","AlbumsV2"],"reset":false}'
curl --fail --silent --show-error -X POST "$base/sync/stream" "${auth[@]}" "${json_header[@]}" \
  -d "$sync_body" -o "$workdir/sync-incremental.jsonl"
grep -q 'SyncCompleteV1' "$workdir/sync-incremental.jsonl"
echo 'API smoke: full and incremental sync passed'

mark_stage acks_and_trash
acks=$(jq -c -s '[.[] | select(.ack != null) | .ack] | unique' "$workdir/sync-incremental.jsonl")
if [[ "$acks" != '[]' ]]; then
  curl --fail --silent --show-error -X POST "$base/sync/ack" "${auth[@]}" "${json_header[@]}" -d "{\"acks\":$acks}"
fi
curl --fail --silent --show-error -X DELETE "$base/sync/ack" "${auth[@]}" "${json_header[@]}" -d '{}'

curl --fail --silent --show-error -X DELETE "$base/assets" "${auth[@]}" "${json_header[@]}" \
  -d "{\"ids\":[\"$still_id\"]}"
curl --fail --silent --show-error -X POST "$base/trash/restore/assets" "${auth[@]}" "${json_header[@]}" \
  -d "{\"ids\":[\"$still_id\"]}"
curl --fail --silent --show-error -X DELETE "$base/assets" "${auth[@]}" "${json_header[@]}" \
  -d "{\"ids\":[\"$still_id\"]}"
curl --fail --silent --show-error -X POST "$base/trash/empty" "${auth[@]}" >/dev/null
curl --fail --silent --show-error -X DELETE "$base/assets" "${auth[@]}" "${json_header[@]}" \
  -d "{\"ids\":[\"$video_id\"],\"force\":true}" >/dev/null
echo 'API smoke: trash, restore, permanent delete passed'

mark_stage reconnect
# Re-login after the destructive round trip to exercise reconnect/session renewal.
curl --fail --silent --show-error -X POST "$base/auth/login" "${json_header[@]}" \
  -d '{"email":"admin@immich.cloud","password":"password"}' | jq -e '.accessToken | type == "string"' >/dev/null

echo "API smoke passed: login, full/incremental sync, upload/download, Live Photo link, album, search, trash restore/empty, and reconnect."
