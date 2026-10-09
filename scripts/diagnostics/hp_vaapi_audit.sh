#!/usr/bin/env bash
# Inventory only: no installs, media jobs, config writes, restarts or benchmarks.
# The sole persistent output is a private report; no credentials/compose/env dumps.
set -uo pipefail
umask 077

report=${1:-/home/doctoriceadm/gallery-vaapi-audit.txt}
if [[ ${1:-} == --help ]]; then
  echo 'Usage: bash hp_vaapi_audit.sh [private-report-path]'
  echo 'Read-only host/container inventory. No benchmark or production changes.'
  exit 0
fi
if [[ -e "$report" || -L "$report" ]]; then
  echo "FAIL: report already exists; archive it yourself before running: $report" >&2
  exit 1
fi
if ! command -v timeout >/dev/null || ! command -v python3 >/dev/null; then
  echo 'FAIL: timeout and python3 are required; nothing was installed.' >&2
  exit 1
fi
if ! (set -o noclobber; : > "$report"); then
  echo 'FAIL: cannot create private report.' >&2
  exit 1
fi

section() { printf '\n== %s ==\n' "$1"; }
probe() {
  local label=$1; shift
  printf '\n-- %s --\n' "$label"
  if timeout 20 "$@"; then
    printf 'PASS: %s (inventory only)\n' "$label"
  else
    local rc=$?
    printf 'UNVERIFIED: %s (exit %s; no corrective action)\n' "$label" "$rc"
  fi
}

inventory() {
  section 'Scope'
  echo 'Read-only snapshot. A node/codec listing is NOT proof of hardware execution.'
  echo 'No individual media paths, tokens, environment dumps, logs or signing material are collected.'
  date -u '+UTC %Y-%m-%dT%H:%M:%SZ'
  probe 'OS/kernel' sh -c 'uname -srv; cat /etc/os-release'
  probe 'CPU' lscpu
  probe 'PCI display devices' sh -c "lspci -nnk | grep -A3 -Ei 'VGA|Display|3D controller'"
  probe 'i915 module' sh -c "lsmod | grep -E '^i915|^xe|^drm'"
  probe 'DRM ownership and access as operator' sh -c '
    id
    getent group render video
    ls -l /dev/dri
    for p in /dev/dri/card* /dev/dri/renderD*; do
      [ -e "$p" ] || continue
      stat -c "%n uid=%u gid=%g mode=%a" "$p"
      if [ -r "$p" ] && [ -w "$p" ]; then echo "PASS: operator can read/write $p";
      else echo "UNVERIFIED: operator cannot read/write $p"; fi
    done'
  probe 'Host installed media/compute drivers' sh -c "dpkg-query -W -f='\${binary:Package} \${Version}\n' 2>/dev/null | grep -Ei '^(intel-media|i965-va|libva|vainfo|mesa-va|intel-gpu|intel-opencl|libigc|libigdgmm|libmfx|libvpl|ffmpeg|linux-firmware)'"
  # Capability query only; never creates/transcodes a media file.
  probe 'Host VAAPI profiles (if vainfo is installed)' vainfo --display drm --device /dev/dri/renderD128
  probe 'Intel GPU inventory (if installed)' intel_gpu_top -L
  probe 'GPU frequency/busy counters, if exposed by the running driver' sh -c '
    for p in /sys/class/drm/card*/device/gpu_busy_percent \
      /sys/class/drm/card*/gt/gt*/rps_act_freq_mhz /sys/class/drm/card*/gt/gt*/rps_cur_freq_mhz; do
      [ -r "$p" ] || continue
      printf "%s=" "$p"; cat "$p"
    done'
  probe 'Memory/swap/load' sh -c 'free -h; swapon --show; uptime; vmstat 1 2'
  # Do not collect process arguments; external jobs can put keys and private paths there.
  probe 'Process resource snapshot, names only' sh -c 'ps -eo comm,pcpu,pmem,rss --sort=-pcpu | head -26'
  probe 'Disk inventory' lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS
  probe 'Mounted storage (no source credentials)' findmnt -rn -o TARGET,FSTYPE,MAJ:MIN
  probe 'Disk capacity (mount targets only)' df -h --output=target,fstype,size,used,avail,pcent
  probe 'Known HP paths, mount identities only' sh -c '
    for p in / /opt/gallery-fork /mnt/hp-data/gallery-fork /mnt/hp-data/immich \
      /mnt/hp-data/build-cache/gradle /mnt/hp-data/build-cache/pub-cache \
      /mnt/hp-data/codex-toolchain/gradle \
      /mnt/hp-data/gallery-inpainting/models/big-lama.pt; do
      [ -e "$p" ] || { echo "UNVERIFIED: absent $p"; continue; }
      readlink -f "$p"
      stat -Lc "%n dev=%d inode=%i type=%F" "$p"
      findmnt -T "$p" -n -o TARGET,FSTYPE,MAJ:MIN
    done
    for p in "$HOME/.gradle" "$HOME/.pub-cache"; do
      [ -e "$p" ] && readlink -f "$p"
    done'
  probe 'External Memories/maintenance service states, no unit contents' systemctl show \
    gallery-ai-daily.service gallery-ai-daily.timer gallery-memory-carousel.service \
    noodle-gallery-maintenance.service noodle-gallery-maintenance.timer \
    -p Id -p ActiveState -p SubState

  section 'Docker (only Gallery/Immich/ML/Memories; no infrastructure mutations)'
  local -a docker_read=(docker)
  if ! timeout 5 docker info --format '{{.DockerRootDir}}' >/dev/null 2>&1; then
    if command -v sudo >/dev/null && timeout 5 sudo -n docker info --format '{{.DockerRootDir}}' >/dev/null 2>&1; then
      docker_read=(sudo -n docker)
    else
      echo 'UNVERIFIED: Docker read access unavailable; no sudo prompt or permission change.'
      return
    fi
  fi
  probe 'Docker root/version' "${docker_read[@]}" info --format 'root={{.DockerRootDir}} server={{.ServerVersion}}'
  local names name
  names=$(timeout 10 "${docker_read[@]}" ps --format '{{.Names}}') || return
  while IFS= read -r name; do
    [[ "$name" =~ ^(immich[_-]|gallery[_-]).* ]] || continue
    # Inspector prints ONLY these fields. Never Config.Env, arguments, labels in full or logs.
    probe "Container $name metadata" "${docker_read[@]}" inspect --format \
      'name={{.Name}} image={{.Config.Image}} imageID={{.Image}} status={{.State.Status}} started={{.State.StartedAt}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} user={{.Config.User}} privileged={{.HostConfig.Privileged}} groups={{json .HostConfig.GroupAdd}} devices={{json .HostConfig.Devices}} deviceRequests={{json .HostConfig.DeviceRequests}} composeFiles={{index .Config.Labels "com.docker.compose.project.config_files"}} composeDir={{index .Config.Labels "com.docker.compose.project.working_dir"}} mounts={{json .Mounts}}' "$name"
    [[ "$name" =~ (server|microservices|machine[_-]learning|memories)$ ]] || continue
    probe "Container $name DRM and FFmpeg inventory" "${docker_read[@]}" exec "$name" sh -c '
      id
      ls -l /dev/dri 2>/dev/null || true
      for p in /dev/dri/renderD*; do
        [ -e "$p" ] || continue
        if [ -r "$p" ] && [ -w "$p" ]; then echo "PASS: container user can access $p";
        else echo "UNVERIFIED: container user cannot access $p"; fi
      done
      if command -v dpkg-query >/dev/null; then
        dpkg-query -W -f="\${binary:Package} \${Version}\n" 2>/dev/null |
          grep -Ei "^(intel-media|i965-va|libva|intel-opencl|libigc|libigdgmm|libmfx|libvpl)" || true
      fi
      if command -v ffmpeg >/dev/null; then
        command -v ffmpeg
        ffmpeg -hide_banner -version
        ffmpeg -hide_banner -hwaccels
        ffmpeg -hide_banner -encoders 2>/dev/null | grep -Ei "vaapi|qsv|264|265|hevc|vp9|av1"
        ffmpeg -hide_banner -decoders 2>/dev/null | grep -Ei "qsv|264|265|hevc|vp9|av1"
        ffmpeg -hide_banner -filters 2>/dev/null | grep -Ei "vaapi|qsv|hw(upload|download)|tonemap|zscale"
      else echo "UNVERIFIED: ffmpeg is absent from container PATH"; fi
      if command -v vainfo >/dev/null; then vainfo --display drm --device /dev/dri/renderD128;
      else echo "UNVERIFIED: container vainfo not installed"; fi'
  done <<< "$names"

  section 'Gallery configuration evidence (whitelisted keys only)'
  # Read a FILE override if configured. This is not necessarily the effective merged config.
  probe 'Server file overrides, if present' "${docker_read[@]}" exec immich_server node -e '
    const fs = require("node:fs");
    const filename = process.env.IMMICH_CONFIG_FILE;
    if (!filename) { console.log("UNVERIFIED: IMMICH_CONFIG_FILE absent; settings can be in DB"); process.exit(0); }
    const c = JSON.parse(fs.readFileSync(filename, "utf8"));
    const f = c.ffmpeg || {};
    const fields = ["accel", "accelDecode", "targetVideoCodec", "targetAudioCodec", "targetResolution", "tonemap", "threads", "transcode"];
    const ffmpeg = Object.fromEntries(fields.filter(k => k in f).map(k => [k, f[k]]));
    const queues = ["videoConversion", "thumbnailGeneration", "smartSearch", "faceDetection", "metadataExtraction"];
    const job = Object.fromEntries(queues.filter(k => c.job?.[k]).map(k => [k, { concurrency: c.job[k].concurrency }]));
    console.log(JSON.stringify({ source: "file overrides, not merged effective config", ffmpeg, job, trash: {enabled:c.trash?.enabled, days:c.trash?.days}, machineLearningEnabled: c.machineLearning?.enabled }, null, 2));'
  # One bounded SELECT. Connection credentials remain inside the existing container.
  # No tables/data/assets are changed; no credential value is read or printed.
  probe 'Persisted server configuration overrides, read-only transaction' "${docker_read[@]}" exec immich_postgres sh -c '
    PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=5000 -c lock_timeout=1000" \
    psql --no-psqlrc -w -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-immich}" -At -v ON_ERROR_STOP=1 -c "$1"' sh "
    SELECT jsonb_build_object(
      'source', 'DB overrides, not merged effective config',
      'ffmpeg', jsonb_build_object(
        'accel', value#>'{ffmpeg,accel}', 'accelDecode', value#>'{ffmpeg,accelDecode}',
        'targetVideoCodec', value#>'{ffmpeg,targetVideoCodec}', 'targetResolution', value#>'{ffmpeg,targetResolution}',
        'tonemap', value#>'{ffmpeg,tonemap}', 'threads', value#>'{ffmpeg,threads}'),
      'job', jsonb_build_object(
        'videoConversion',value#>'{job,videoConversion,concurrency}',
        'thumbnailGeneration',value#>'{job,thumbnailGeneration,concurrency}',
        'smartSearch',value#>'{job,smartSearch,concurrency}',
        'faceDetection',value#>'{job,faceDetection,concurrency}'),
      'trash', jsonb_build_object('enabled',value#>'{trash,enabled}','days',value#>'{trash,days}'),
      'machineLearningEnabled',value#>'{machineLearning,enabled}')
    FROM system_metadata WHERE key='system-config';"
  probe 'Public server version (no authentication)' curl --fail --silent --show-error \
    --connect-timeout 3 --max-time 8 http://127.0.0.1:2283/api/server/version
  echo
  echo 'UNVERIFIED: effective Admin settings/job queue and external renderer configuration require owner confirmation.'
  echo 'Do not upload credentials, full Compose/env, media listings or private job logs.'
}

inventory > "$report" 2>&1
printf 'PASS: private inventory saved: %s\n' "$report"
printf 'Review this report before uploading. Missing probes are UNVERIFIED, not evidence of working acceleration.\n'
