#!/usr/bin/env bash
# Read-only HP source preflight. It supports normal checkouts and linked
# worktrees, whose .git entry is a file. It never fetches, resets, switches,
# writes source files, or touches production services.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: hp-preflight.sh --repo PATH --expected-sha SHA [--manifest PATH]
USAGE
}

repo=''
expected=''
manifest=''
while (($#)); do
  case "$1" in
    --repo) repo=${2:?missing path}; shift 2 ;;
    --expected-sha) expected=${2:?missing SHA}; shift 2 ;;
    --manifest) manifest=${2:?missing manifest}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$repo" && -n "$expected" ]] || { usage; exit 2; }
[[ "$expected" =~ ^[0-9a-f]{40}$ ]] || { echo 'expected SHA must be a full 40-character lowercase commit' >&2; exit 2; }

# git -C resolves both a directory .git and a worktree .git file.
top=$(git -C "$repo" rev-parse --show-toplevel)
git_dir=$(git -C "$repo" rev-parse --git-dir)
actual=$(git -C "$repo" rev-parse HEAD)
branch=$(git -C "$repo" symbolic-ref --quiet --short HEAD || printf '(detached)')
[[ "$actual" == "$expected" ]] || { echo "HEAD mismatch: expected $expected, got $actual" >&2; exit 1; }
[[ -z "$(git -C "$repo" status --porcelain=v1)" ]] || { echo 'working tree is dirty; save changes before HP handoff' >&2; exit 1; }
origin=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
case "${origin%.git}" in
  https://github.com/docice545/gallery|git@github.com:docice545/gallery) ;;
  *) echo 'origin is not docice545/gallery; refusing handoff' >&2; exit 1 ;;
esac

if [[ -n "$manifest" ]]; then
  python3 - "$manifest" "$expected" <<'PY'
import json
import re
import sys
from pathlib import Path
path = Path(sys.argv[1])
expected = sys.argv[2]
data = json.loads(path.read_text())
if data.get('sourceSha') != expected or data.get('currentRcHead') != expected:
    raise SystemExit('release manifest sourceSha/currentRcHead does not match expected SHA')
if data.get('releaseStatus') == 'READY':
    raise SystemExit('manifest cannot claim READY before HP/device gates')
if data.get('android', {}).get('packageId') != 'de.opennoodle.gallery':
    raise SystemExit('manifest package ID mismatch')
if data.get('android', {}).get('versionCode', 0) <= 21:
    raise SystemExit('manifest versionCode must be greater than installed Build 21')
if not re.fullmatch(r'[0-9a-f]{64}', data.get('android', {}).get('signingCertificateSha256', '')):
    raise SystemExit('manifest signing certificate digest is missing or malformed')
PY
fi

printf 'PASS read-only HP preflight\nrepo=%s\ngitDir=%s\nbranch=%s\nHEAD=%s\norigin=%s\n' "$top" "$git_dir" "$branch" "$actual" "$origin"
