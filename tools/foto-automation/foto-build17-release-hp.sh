#!/usr/bin/env bash
# HP-only pinned build/verify launcher; never deploys or reruns completed tests.
set -euo pipefail
umask 077
foto_launch_exit() {
  local FOTO_EXIT_STATUS=$1
  if [ "$FOTO_EXIT_STATUS" -ne 0 ]; then
    printf 'STOP exit=%s; private preflight reports: %s*; state not reset\n' "$FOTO_EXIT_STATUS" "${FOTO_REPORT:-not-created}" >&2
  fi
}
trap 'foto_launch_exit "$?"' EXIT
FOTO_TOOLS_SHA=9743a191e50ffc373abd848e45ab3fd97f61bbfa
FOTO_INSTALL=/usr/local/lib/foto-build17-release/$FOTO_TOOLS_SHA
FOTO_STAGE=$(mktemp -d /tmp/foto17-psi-install.XXXXXXXX)
FOTO_RELEASE_CONFIG=/mnt/hp-data/codex-home/foto-build17-release-check-0bd44fb68.json
FOTO_PIN_FORMAT_PROOF=$FOTO_RELEASE_CONFIG.before-pin-normalization
[[ "$FOTO_RELEASE_CONFIG" = /* ]]
sudo -u codex-gallery -H test -f "$FOTO_RELEASE_CONFIG"
sudo -u codex-gallery -H python3 - "$FOTO_PIN_FORMAT_PROOF" <<'PY_PRIVATE_PROOF'
import os, pathlib, stat, sys
proof = pathlib.Path(sys.argv[1])
s = proof.lstat()
if not (stat.S_ISREG(s.st_mode) and s.st_uid == os.getuid()
        and stat.S_IMODE(s.st_mode) == 0o600):
    raise SystemExit('STOP: original backup must already be owned by codex-gallery, regular and 0600; unchanged')
print('PASS original backup owner/type/mode (read-only)')
PY_PRIVATE_PROOF
foto_as_builder() {
  sudo -u codex-gallery -H env \
    PATH="/mnt/hp-data/codex-home/.npm-global/bin:/mnt/hp-data/codex-toolchain/flutter/bin:/mnt/hp-data/codex-toolchain/gradle/gradle-8.14/bin:/mnt/hp-data/codex-toolchain/node/bin:/mnt/hp-data/codex-toolchain/node/lib/node_modules/corepack/shims:/mnt/hp-data/codex-toolchain/bun/bin:/mnt/hp-data/codex-toolchain/android-sdk/cmdline-tools/latest/bin:/usr/local/bin:/usr/bin:/bin" \
    ANDROID_HOME=/mnt/hp-data/codex-toolchain/android-sdk \
    ANDROID_SDK_ROOT=/mnt/hp-data/codex-toolchain/android-sdk \
    PUB_CACHE=/mnt/hp-data/codex-toolchain/cache/pub \
    GRADLE_USER_HOME=/mnt/hp-data/codex-toolchain/cache/gradle \
    bash -c '
      set -euo pipefail
      cd /mnt/hp-data/codex-work/foto-build17-integration-review/mobile
      if ! command -v mise >/dev/null; then
        echo "STOP: existing mise is not in the codex-gallery toolchain PATH" >&2
        exit 1
      fi
      # No TOOL@VERSION arguments: env reports missing config tools, never installs them.
      FOTO_ENV=$(mise env -s bash)
      eval "$FOTO_ENV"
      unset FOTO_ENV
      exec "$@"
    ' foto17-release "$@"
}
if sudo -u codex-gallery -H tmux -L foto17-psi-build list-sessions >/dev/null 2>&1; then
  echo 'STOP: сессия foto17-psi-build уже существует; подключитесь к ней, не запускайте вторую.' >&2
  exit 1
fi
for f in foto-build17-release foto-stage-runner.py foto-mobile-codegen.sh foto-android-build.sh foto-build17-release.example.json; do
  sudo -u codex-gallery -H gh api \
    "repos/docice545/gallery/contents/tools/foto-automation/$f?ref=$FOTO_TOOLS_SHA" \
    --jq .content | base64 --decode > "$FOTO_STAGE/$f"
done
cat > "$FOTO_STAGE/SHA256SUMS" <<'SHA256SUMS'
cf6d5e60365942bbf7fa28a020a3e7e19611fdc4d9ffbee72d62d7472ae6c21a  foto-build17-release
520b1582135cd54ee96508e6a228551b45ef6d207b6db1010d9813c23efb4b40  foto-stage-runner.py
f5183332c0ed397cd929d07b468dc997fd51516b6b27f021c0ce27df91d9bb2e  foto-mobile-codegen.sh
afaecc5b28c2f8d4bb926f1eaedfe9e34926ea3117f0c31523fb5eb4a869aca4  foto-android-build.sh
2459818bce7f57d6e9692220473d8ca23db34ac78d7de7f55cae299ac25e15a9  foto-build17-release.example.json
SHA256SUMS
(cd "$FOTO_STAGE" && sha256sum --check SHA256SUMS)
for d in /usr/local/lib/foto-build17-release "$FOTO_INSTALL"; do
  if sudo test -e "$d" || sudo test -L "$d"; then
    sudo test -d "$d"
    sudo test ! -L "$d"
    [[ "$(sudo stat -c '%u:%a' "$d")" = 0:755 ]]
  else
    sudo install -d -m0755 "$d"
  fi
done
for f in foto-build17-release foto-stage-runner.py foto-mobile-codegen.sh foto-android-build.sh foto-build17-release.example.json; do
  if sudo test -e "$FOTO_INSTALL/$f" || sudo test -L "$FOTO_INSTALL/$f"; then
    sudo test ! -L "$FOTO_INSTALL/$f"
    sudo cmp -s "$FOTO_STAGE/$f" "$FOTO_INSTALL/$f"
  else
    MODE=0755
    if [ "$f" = foto-build17-release.example.json ]; then MODE=0644; fi
    sudo install -m "$MODE" "$FOTO_STAGE/$f" "$FOTO_INSTALL/$f"
  fi
done
foto_checkpoint() {
  sudo -u codex-gallery -H python3 - "$FOTO_RELEASE_CONFIG" <<'PY_CHECKPOINT'
import hashlib, json, pathlib, subprocess, sys
config = json.loads(pathlib.Path(sys.argv[1]).read_text())
raw = (pathlib.Path(config['state']) / 'manifest.json').read_bytes()
state = json.loads(raw)
expected = 'e5883358c48a76a82fe7db29b5cd5ac0b1fc76e2'
names, stages = state.get('testsComplete', []), state.get('stages', {})
if not (state.get('prepared') is True and state.get('mode') == 'build'
        and state.get('head') == expected and len(names) == 50 and len(set(names)) == 50
        and set(stages) == set(names) and all(r.get('status') == 'PASS' and r.get('exitCode') == 0
            and r.get('inputs', {}).get('pipeline') == 'c460031cab860039d7017459d1fa42ee13261e9ddb35fe75c637ee96b795e7bf'
            for r in stages.values()) and state.get('history')
        and state['history'][-1].get('event') == 'BUILD_REQUESTED'):
    raise SystemExit('STOP: checkpoint differs from confirmed 50 PASS / pre-backend state; nothing reset')
head = subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null', '-C', state['worktree'],
                                'rev-parse', 'HEAD'], text=True).strip()
if head != expected:
    raise SystemExit('STOP: prepared worktree HEAD differs; nothing reset')
print(json.dumps({'manifestSHA256': hashlib.sha256(raw).hexdigest(), 'head': expected,
                  'testNames': names, 'testReceiptsSHA256': hashlib.sha256(
                      json.dumps(stages, sort_keys=True).encode()).hexdigest()}, sort_keys=True))
PY_CHECKPOINT
}
FOTO_CHECKPOINT_BEFORE=$(foto_checkpoint)
FOTO_REPORT=$(mktemp /home/doctoriceadm/FOTO17-final-preflight.XXXXXXXX.txt)
foto_as_builder "$FOTO_INSTALL/foto-build17-release" \
  --config "$FOTO_RELEASE_CONFIG" --certificate-pin-format-proof "$FOTO_PIN_FORMAT_PROOF" \
  --check > "$FOTO_REPORT" 2> "$FOTO_REPORT.stderr"
python3 - "$FOTO_REPORT" <<'PY_VALIDATION'
import json, pathlib, sys
report = json.loads(pathlib.Path(sys.argv[1]).read_text())
if report.get('checkpointConfigValidation') != 'PASS_CERTIFICATE_PIN_FORMAT_EQUIVALENT':
    raise SystemExit('STOP: config equivalence not proved; checkpoint/backup unchanged')
if report.get('docker', {}).get('builderValidation') != 'PASS_READ_ONLY_LIMITS_AND_IDLE':
    raise SystemExit('STOP: builderValidation is not PASS; inspect the private preflight report')
print('PASS builderValidation=PASS_READ_ONLY_LIMITS_AND_IDLE')
print('PASS checkpointConfigValidation=PASS_CERTIFICATE_PIN_FORMAT_EQUIVALENT')
PY_VALIDATION
[[ "$(foto_checkpoint)" = "$FOTO_CHECKPOINT_BEFORE" ]] || {
  echo 'STOP: checkpoint changed during check; nothing reset' >&2
  exit 1
}
FOTO_SESSION=$(sudo -u codex-gallery -H mktemp -d /mnt/hp-data/codex-work/foto17-psi-session.XXXXXXXX)
printf '%s\n' "$FOTO_CHECKPOINT_BEFORE" | \
  sudo -u codex-gallery -H sh -c 'umask 077; cat > "$1"' sh "$FOTO_SESSION/accepted-tests.json"
# Read-only admission: all receipts must already be PASS. No test/build command
# can execute on this path; stage() verifies each existing receipt and returns.
foto_as_builder python3 - "$FOTO_INSTALL/foto-build17-release" "$FOTO_RELEASE_CONFIG" "$FOTO_PIN_FORMAT_PROOF" \
  > "$FOTO_REPORT.receipts" 2> "$FOTO_REPORT.receipts.stderr" <<'PY_ADMIT'
import importlib.machinery, importlib.util, pathlib, sys
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader('foto_memory_admission', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
app = importlib.util.module_from_spec(spec)
loader.exec_module(app)
p = app.Pipeline(app.config(pathlib.Path(sys.argv[2])), pin_format_proof=pathlib.Path(sys.argv[3]))
p.read_checkpoint()
recipes = app.recipes_for(p.source())
app.need(p.manifest.get('testsComplete') == [x[0] for x in recipes] and len(recipes) == 50
         and all(p.manifest['stages'].get(x[0], {}).get('status') == 'PASS' for x in recipes),
         'MANDATORY_CHECKS_INCOMPLETE_NO_TESTS_RERUN')
for name, folder, argv, outputs in recipes:
    p.stage(name, p.source() / folder, argv, outputs)
app.check_stage_memory('backend-image', app.resources())
app.builder_idle()
print('PASS memory admission and 50 receipts revalidated read-only; no test executed')
PY_ADMIT
tail -n 1 "$FOTO_REPORT.receipts"
[[ "$(foto_checkpoint)" = "$FOTO_CHECKPOINT_BEFORE" ]]
printf '%s\n' 'set-option -g remain-on-exit on' 'set-option -g history-limit 20000' | \
  sudo -u codex-gallery -H sh -c 'umask 077; cat > "$1"' sh "$FOTO_SESSION/tmux.conf"
sudo -u codex-gallery -H sh -c 'umask 077; cat > "$1"' sh "$FOTO_SESSION/run-build.sh" <<'BUILD_ONLY'
#!/usr/bin/env bash
set -euo pipefail
umask 077
exec > >(tee "$4/final-build.log") 2>&1
"$1" --config "$2" --certificate-pin-format-proof "$3" --build
"$1" --config "$2" --certificate-pin-format-proof "$3" --verify
python3 - "$2" "$4/accepted-tests.json" <<'PY_PRESERVED'
import hashlib, json, pathlib, sys
c = json.loads(pathlib.Path(sys.argv[1]).read_text())
state = json.loads((pathlib.Path(c['state']) / 'manifest.json').read_text())
before = json.loads(pathlib.Path(sys.argv[2]).read_text())
tests = {n: state['stages'][n] for n in before['testNames']}
if (state['head'] != before['head'] or hashlib.sha256(json.dumps(tests, sort_keys=True).encode()).hexdigest()
        != before['testReceiptsSHA256']):
    raise SystemExit('STOP: original test receipts changed; preserve logs, do not reset')
print('PASS original 50 receipts unchanged; backend image and signed APK verified; no deployment')
print('Public artifact receipt:', state['exportReceipt'])
PY_PRESERVED
BUILD_ONLY
foto_as_builder tmux -L foto17-psi-build -f "$FOTO_SESSION/tmux.conf" \
  new-session -d -s foto17-psi-build /bin/bash "$FOTO_SESSION/run-build.sh" \
  "$FOTO_INSTALL/foto-build17-release" "$FOTO_RELEASE_CONFIG" "$FOTO_PIN_FORMAT_PROOF" "$FOTO_SESSION"
printf 'STARTED, не READY. Preflight: %s\n' "$FOTO_REPORT"
printf 'Журнал сборки: %s/final-build.log\n' "$FOTO_SESSION"
printf '%s\n' 'Ход/результат: sudo -u codex-gallery -H tmux -L foto17-psi-build attach -t foto17-psi-build'
