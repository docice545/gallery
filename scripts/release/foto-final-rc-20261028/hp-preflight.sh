#!/usr/bin/env bash
set -euo pipefail

root=${1:?"usage: hp-preflight.sh CHECKOUT FULL_RC_SHA"}
expected=${2:?"usage: hp-preflight.sh CHECKOUT FULL_RC_SHA"}
[[ $expected =~ ^[0-9a-f]{40}$ ]] || { echo 'BLOCKED invalid full SHA'; exit 2; }
[[ -d $root/.git ]] || { echo "BLOCKED checkout missing: $root"; exit 2; }
git -C "$root" diff --quiet || { echo 'BLOCKED dirty checkout'; exit 2; }
[[ $(git -C "$root" rev-parse HEAD) == "$expected" ]] || { echo 'BLOCKED checkout SHA mismatch'; exit 2; }
git -C "$root" worktree list --porcelain
df -h "$root"
if command -v docker >/dev/null 2>&1; then
  docker version --format 'docker={{.Server.Version}}' || echo 'BLOCKED docker daemon unavailable'
  docker ps --format 'container={{.Names}} state={{.Status}}' || true
else
  echo 'BLOCKED docker binary unavailable'
fi
if [[ -f /home/doctoriceadm/foto-build21-release/FOTO-5.7.3-build21.apk ]]; then
  sha256sum /home/doctoriceadm/foto-build21-release/FOTO-5.7.3-build21.apk
else
  echo 'BLOCKED Build 21 APK path missing'
fi
[[ -f /opt/immich/docker-compose.yml ]] && echo 'compose=present' || echo 'BLOCKED compose path missing'
echo 'PASS read-only HP preflight; no services, database, NAS or APK were changed'
