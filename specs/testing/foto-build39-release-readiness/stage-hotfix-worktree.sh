#!/usr/bin/env bash
# PREPARATION ONLY: independent detached worktree, no keys/build/sign/install.
set -euo pipefail
umask 077
FOTO_HP=/mnt/hp-data/foto-build38/source
FOTO_HP_SHA=54f335e2a28af2de6d485f5a53acb05934837324
FOTO_HOTFIX=fc1126dd4a283d7ab803c237d45914b3d60b5568
cd "$FOTO_HP"
test "$(git rev-parse HEAD)" = "$FOTO_HP_SHA"
test "$(git branch --show-current)" = foto-build39-hp-serial-tests
# Hash the existing index/worktree diffs without displaying file contents.
FOTO_BEFORE=$(python3 - <<'PY'
import hashlib,subprocess
h=hashlib.sha256()
for args in [['status','--porcelain=v1','-z','--untracked-files=all'],['diff','--binary'],['diff','--cached','--binary']]:
 data=subprocess.check_output(['git',*args]); h.update(len(data).to_bytes(8,'big')); h.update(data)
print(h.hexdigest())
PY
)
git -c core.hooksPath=/dev/null -c maintenance.auto=false fetch --no-tags origin refs/heads/codex/foto-build38-unified-16
git cat-file -e "$FOTO_HOTFIX^{commit}"
FOTO_CANDIDATE=$(mktemp -d /mnt/hp-data/foto-build38/hotfix-fc1126dd4-XXXXXX)
git -c core.hooksPath=/dev/null worktree add --detach "$FOTO_CANDIDATE" "$FOTO_HOTFIX"
test "$(git -C "$FOTO_CANDIDATE" rev-parse HEAD)" = "$FOTO_HOTFIX"
test -z "$(git -C "$FOTO_CANDIDATE" status --porcelain)"
test "$(git rev-parse HEAD)" = "$FOTO_HP_SHA"
test "$(git branch --show-current)" = foto-build39-hp-serial-tests
FOTO_AFTER=$(python3 - <<'PY'
import hashlib,subprocess
h=hashlib.sha256()
for args in [['status','--porcelain=v1','-z','--untracked-files=all'],['diff','--binary'],['diff','--cached','--binary']]:
 data=subprocess.check_output(['git',*args]); h.update(len(data).to_bytes(8,'big')); h.update(data)
print(h.hexdigest())
PY
)
test "$FOTO_BEFORE" = "$FOTO_AFTER"
test ! -e "$FOTO_CANDIDATE/mobile/android/key.jks"
test ! -e "$FOTO_CANDIDATE/mobile/android/key.properties"
printf 'CANDIDATE=%s\nHP_HEAD_PRESERVED=%s\n' "$FOTO_CANDIDATE" "$FOTO_HP_SHA"
# Detached checkout is for review; current android_release.py requires a named
# candidate branch for a later authorized build. Never run it against HP here.
