#!/usr/bin/env bash
# Executed ONLY inside the locked, unprivileged sandbox session.
set -euo pipefail
STATE_DIR=$1
CONTINUATION=$2
[[ "${FOTO_SESSION_ACTIVE:-}" == 1 && ! -L "$STATE_DIR/prompts/user-task.txt" ]] || exit 2
umask 077
TMP=$(mktemp "$STATE_DIR/prompts/.user-task.XXXXXXXX")
trap 'rm -f -- "$TMP"' EXIT
printf '%s\n' 'Введите новый промпт. Ctrl+D без текста продолжает предыдущий.'
cat > "$TMP"
if [[ -s "$TMP" ]]; then
  if [[ -f "$STATE_DIR/prompts/user-task.txt" ]]; then
    cp -- "$STATE_DIR/prompts/user-task.txt" "$TMP.previous"
  fi
  mv -- "$TMP" "$STATE_DIR/prompts/user-task.txt"
fi
rm -f -- "$TMP"
exec /bin/bash "$CONTINUATION" --resume
