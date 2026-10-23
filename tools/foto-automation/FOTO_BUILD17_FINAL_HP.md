# FOTO Build 17: продолжить сборку после memory gate на HP

Это продолжение **уже подготовленного** backend image/APK release, **без deployment**.
Запускает doctoriceadm. В checkpoint подтверждены **50 обязательных PASS**, а не
49 (исправлено оператором после чтения manifest). `testsComplete` содержит все
50 имён; прежний runtime SHA256:
`c460031cab860039d7017459d1fa42ee13261e9ddb35fe75c637ee96b795e7bf`.
Сборка остановилась **до** `backend-image`, без RUNNING/FAIL build receipt.

Новый memory gate: backend требует `MemAvailable >= 10 GiB`, `MemTotal >= 14 GiB`
(минимум 4 GiB физической RAM вне уже существующего потолка BuildKit10GiB),
нулевые PSI some/full avg10/60/300 и минимум 10 GiB headroom относительно каждого
конечного memory.max/memory.high текущего cgroup и всех видимых предков.
Неполные/нечитаемые наблюдения — STOP. Swap не засчитывается как RAM.
У остальных этапов прежние 5 GiB available / 6 GiB caller-limit floor.
10 GiB BuildKit — потолок, не заранее выделенная память; это консервативная
проверка допуска, **не доказательство устранения реального OOM**. Нагрузка после
допуска может измениться. Лимиты10g/12g и max-parallelism1 остаются прежними.

Обновление сохраняет единственное доказанное изменение
config: `signing.certificate_sha256` из 32 hex-байтов с двоеточиями в 64 lowercase
hex. Исходный приватный backup должен соответствовать прежнему hash checkpoint;
весь остальной config должен совпасть. Исправления Buildx v0.35.0 (текстовый
inspect и JSON history с `status`) сохраняются. Старые runners не перезаписываются.

Оператор подтвердил checkpoint: `prepared=true`, HEAD
`e5883358c48a76a82fe7db29b5cd5ac0b1fc76e2`, все 50 тестовых этапов PASS.
Опубликованный runner сохраняет `mode=build` / `BUILD_REQUESTED` до memory STOP.
Блок ниже требует именно эту точку, полный список PASS и отсутствие build receipt.
При отличии он останавливается. Он не правит вручную manifest/config,
не выполняет повторный merge PR6/PR7 и не сбрасывает подготовленный worktree.
Не запускайте Codex/другую сборку одновременно. Существующий config должен уже
содержать проверенные PR6/PR7 SHA, approvals и реальные пути старого ключа и
key.properties с доверенным fingerprint сертификата. Ключи/пароли не копируются
и не публикуются. Подтверждённый оператором прежний config:
`/mnt/hp-data/codex-home/foto-build17-release-check-0bd44fb68.json`.
Инструкция использует его без изменения и не создаёт заменяющий config/state.

Подтверждённый backup:
`/mnt/hp-data/codex-home/foto-build17-release-check-0bd44fb68.json.before-pin-normalization`.
Новый явный аргумент `--certificate-pin-format-proof` читает его при каждой проверке
идентичности. Требуются regular file, без symlink, владелец codex-gallery и ровно
0600. Владелец проверяется на HP; доступность чтения сама по себе недостаточна.
Блок ничего не chmod/chown в config/backup. При отличии владельца/прав — STOP;
backup не надо «чинить» или пересоздавать для обхода проверки.

Hash исходного config в manifest остаётся прежним. Никакие файлы config, backup,
прежние snapshots или stage receipts не переписываются. Новые события выполнения
сохраняются обычным append/snapshot механизмом runner. После первого запуска
этот же backup и флаг нужны также для `--resume` / `--verify`: отсутствие доказательства,
смена сертификата, любого другого поля/типа config или SHA входов запрещают reuse.

Блок активирует **уже установленную** toolchain через `mise env` из существующего
checkout. Он не запускает Codex launcher и не наследует его старый JDK17:
repository pins требуют JDK21.0.2. Android SDK и кеши берутся из существующего
`/mnt/hp-data/codex-toolchain`. Отсутствующая mise/toolchain — явный STOP;
системные инструменты, лимиты и builder этим блоком не устанавливаются и не меняются.

## Один блок: установить исправленный инструмент, проверить и запустить

Исходный checkout, старые инструменты, config, manifest, snapshots и ключи
сохраняются. Устанавливаются только пять проверенных файлов в новый каталог.
`sudo` здесь — явное действие doctoriceadm; внутри release-конвейера его нет.
Для нового tmux используется отдельный socket, существующие сессии не меняются.

```bash
bash <<'BASH'
set -euo pipefail
umask 077
trap 's=$?; if [ "$s" -ne 0 ]; then printf "STOP exit=%s; private preflight reports: %s*; state not reset\n" "$s" "${FOTO_REPORT:-not-created}" >&2; fi' EXIT
FOTO_TOOLS_SHA=da40b0b9f288ff9be96428edb728dbd437eff22d
FOTO_INSTALL=/usr/local/lib/foto-build17-release/$FOTO_TOOLS_SHA
FOTO_STAGE=$(mktemp -d /tmp/foto17-memory-install.XXXXXXXX)
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
if sudo -u codex-gallery -H tmux -L foto17-memory-build list-sessions >/dev/null 2>&1; then
  echo 'STOP: сессия foto17-memory-build уже существует; подключитесь к ней, не запускайте вторую.' >&2
  exit 1
fi
for f in foto-build17-release foto-stage-runner.py foto-mobile-codegen.sh foto-android-build.sh foto-build17-release.example.json; do
  sudo -u codex-gallery -H gh api \
    "repos/docice545/gallery/contents/tools/foto-automation/$f?ref=$FOTO_TOOLS_SHA" \
    --jq .content | base64 --decode > "$FOTO_STAGE/$f"
done
cat > "$FOTO_STAGE/SHA256SUMS" <<'SHA256SUMS'
1608ca69de6eafa1fa52d0a311c44a8fae6e016fa8b5845b09fc6515b57cc476  foto-build17-release
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
FOTO_SESSION=$(sudo -u codex-gallery -H mktemp -d /mnt/hp-data/codex-work/foto17-memory-session.XXXXXXXX)
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
foto_as_builder tmux -L foto17-memory-build -f "$FOTO_SESSION/tmux.conf" \
  new-session -d -s foto17-memory-build /bin/bash "$FOTO_SESSION/run-build.sh" \
  "$FOTO_INSTALL/foto-build17-release" "$FOTO_RELEASE_CONFIG" "$FOTO_PIN_FORMAT_PROOF" "$FOTO_SESSION"
printf 'STARTED, не READY. Preflight: %s\n' "$FOTO_REPORT"
printf 'Журнал сборки: %s/final-build.log\n' "$FOTO_SESSION"
printf '%s\n' 'Ход/результат: sudo -u codex-gallery -H tmux -L foto17-memory-build attach -t foto17-memory-build'
BASH
```

`--check` — read-only inventory, exit0 сам по себе не означает готовность к сборке.
Дополнительный read-only gate проверяет все 50 существующих PASS и их полные
inputs/logs/outputs; никакая тестовая команда на этом пути не запускается.
Только точный прежний SHA runtime и reviewed application tree допускают reuse.
Путь прежнего `foto-mobile-codegen.sh` допускается только при совпадении SHA его
байтов с новым helper и закреплённым SHA. Другие argv или runtimes запрещены.

В tmux запускаются только `--build`, затем `--verify`. Нет `--prepare`, `--test`,
`--finalize`, fetch, merge и автоматического retry. `build()` ещё раз проверяет
receipt и выводит `PASS_REUSED`, без запуска тестов. Неполный/failed набор
останавливается **до** этого цикла; отсутствующий receipt не запускает тест заново.
У новых backend/APK receipts будет новый SHA runtime; прежние 50 JSON-объектов
сохраняют все значения и остаются привязаны к старому SHA. Финальная проверка
подтверждает их общий canonical JSON checksum. Manifest штатно получает новые build/verify
события и неизменяемые snapshots, а не переписывает историю и результаты тестов.
Каждый режим держит прежние common locks; конкурирующий запуск между режимами
также приводит к STOP, не обходу блокировки. Ошибка build не запускает verify.

## Результат и повторное подключение

После обрыва SSH подключиться:

```bash
sudo -u codex-gallery -H tmux -L foto17-memory-build attach -t foto17-memory-build
```

Сессия сохраняет pane после выхода программы. Exit status:

```bash
sudo -u codex-gallery -H tmux -L foto17-memory-build display-message -p -t foto17-memory-build '#{pane_dead_status}'
```

Пустое значение означает, что процесс ещё не завершён. Exit0 вместе с финальной
JSON-квитанцией/`ARTIFACTS_VERIFIED_READY_FOR_MANUAL_DEVICE_ACCEPTANCE_NOT_DEPLOYMENT`
в истории manifest подтверждает проверки артефактов, но не работу на устройстве.
Image получает тег `foto-build17:<полный integration SHA>`. APK и публичная
квитанция экспортируются в `/var/tmp/foto-build17-release-artifacts/`; точные
имя, размер, SHA256, package/version и certificate SHA256 печатаются после verify.
Только готовый APK можно затем скопировать через выведенную команду `--receive-apk`
от doctoriceadm; существующий файл другой версии не перезаписывается.

Все объёмные stage logs и неизменяемые manifest snapshots остаются в исходном
release state из config. Preflight TXT — приватный, не публикуйте без просмотра.
`final-build.log` находится в новом session-каталоге, путь печатается при запуске.
Docker ID `sha256:...` — identity локального образа. Registry RepoDigest не
выдумывается: образ не публикуется в registry. APK проверяется `apksigner verify`,
package/version/certificate pin и SHA256; реальное устройство этим не проверено.

## Если сборка остановилась

- Снова `PARTIALLY_APPLIED_PR_REVIEW_REQUIRED`: HEAD/base/frontier не совпали с
  reviewed набором. Ничего не reset/clean и не редактировать manifest.
- `REVIEWED_OVERLAP_TREE_DIFFERS...` / `REVIEWED_MERGE_RESULT_DIFFERS...`:
  неизвестный результат Git; worktree и intent сохранены, нужна отдельная проверка.
- `MERGE_INTERRUPTED...`: реальный merge был прерван; этот patch не разрешает
  автоматически чинить его. Не удалять MERGE_HEAD/checkpoint.
- `CONFIG_CHANGED_USE_NEW_STATE` / `STAGE_INPUT_CHANGED_NEW_STATE_REQUIRED`:
  доказательство config не совпало, либо старые receipts принадлежат другим входам.
  Сохранить backup/state; не подменять hashes. Этот patch принимает только точное
  преобразование pin; другие изменения запрещены. Без proof-флага по-прежнему STOP.
- `PRIVATE_0600_OWNED_FILE_REQUIRED` / `PIN_FORMAT_PROOF_REQUIRES_PREPARED_CHECKPOINT`:
  исходный backup/подготовленный checkpoint не доказан. Ничего не пересоздавать,
  не править права/manifest и не повторять merge; сохранить приватный отчёт.
- `MISSING_TOOL_*` / JDK / signing error: исправить только указанную существующую
  toolchain/config после локальной проверки. Новый ключ создавать запрещено.
- OOM137/DeadlineExceeded: сохранить logs и установить причину. Автоповторов нет;
  `--retry-failed --diagnosis` применяется только после реальной диагностики.
- `INSUFFICIENT_HOST_MEMORY_RESERVE` / `CALLER_CGROUP_MEMORY_RESERVE` /
  `MEMORY_PRESSURE` / `MEMORY_PSI_UNKNOWN` / `BACKEND_MEMORY_OBSERVATIONS_UNAVAILABLE`:
  не доказан запас RAM или отсутствие давления. Не менять лимиты и не останавливать
  production. Сохранить private reports, продолжение запрещено до отдельной проверки.
- `REVIEWED_PREDECESSOR_*` / `MANDATORY_CHECKS_INCOMPLETE`:
  старый runtime/application/PASS набор отличается. Не переписывать SHA или PASS.

Откат инструмента — использовать прежний versioned executable для read-only
диагностики со старым config. Не пытаться продолжать новые receipts старым кодом.
Откат integration source не требует reset: исходная unified-ветка и её рабочая
копия вообще не изменяются. Новые локальные merge commits/state сохраняются для
разбора. Production rollback/deployment не входят в этот сценарий.

## Проверка Buildx v0.35.0

Runner использует поддерживаемый текстовый `docker --context rootless buildx inspect
foto17-limited`. Требуются Driver `docker-container`, ровно один node
`foto17-limited0`, Endpoint `rootless`, Status `running`. Отсутствующие,
дублированные, неоднозначные поля и Error отвергаются. Дополнительные labels,
GC policy и вложенные device names не считаются nodes.

Отдельные проверки точного rootless socket, фактических memory10GiB/swap12GiB
контейнера BuildKit, Running/noOOM, worker max-parallelism=1 и отсутствия активных
сборок не изменены. Нет bootstrap/create/restart/prune и новых builders.

History читается как JSONL с обязательным строковым `status` нижнего регистра.
`Completed`, `Completed`, `Error` принимаются. `Running`, неизвестные/нестроковые
состояния, отсутствие поля, верхний `Status` вместо `status`, повреждённый JSON,
дублирующие ключи, пустая/недоступная история запрещают сборку. Прежние разрешённые
терминальные `Canceled`/`Cancelled` сохраняются. Никаких предположений «нет строк —
значит idle» нет. Поля сверены с `lsContext.MarshalJSON()` тега v0.35.0.

В Cloud выполнены 15 адресных тестов: JSON history, текстовый inspect, отказы, все прежние guards,
`--check` с `builderValidation=PASS_READ_ONLY_LIMITS_AND_IDLE`, сохранность байтов
checkpoint и возобновление PREPARED без повторного merge. Настоящий старый код
`e603d937ef9f73da33abf85482bf2fd3f5f83395` воспроизводит STOP на JSON fixture
с корректными полями v0.35.0; новый код принимает те же данные. В fixture используются
синтетические refs/время и подтверждённая оператором последовательность состояний,
это не публикация production history и не фактический NFS/Docker E2E. Docker/HP сервисы в
фикстурах подменены — это **не реальный HP E2E**. Подлинный release binary
Buildx v0.35.0 (`a319e5b15052cf6557ceb666eb8ff6e32380b782`, linux-amd64 SHA256
`d41ece72044243b4f58b343441ae37446d9c29a7d6b5e11c61847bbcf8f7dfda`)
проверен на `version`, `inspect --help` и отказ старого `--format` без контакта
с Docker daemon. Реальная проверка builder/продолжение выполняется только HP-блоком.

## Что подтверждено и что ещё нет

Memory/reuse/launcher update: 17 адресных тестов PASS (16 новых, один прежний memory test)
и 12 связанных регрессий/сравнений с опубликованным предшественником PASS.
Проверены границы10GiB/5GiB/host reserve4GiB, PSI обоих типов и всех окон,
неизвестные/отсутствующие данные, max/high/current и конечные лимиты предков,
запрет credit swap, STOP до build intent, reuse всех **50 синтетических** receipts
без child execution и без записи, попытки подмены runtime/команд/config/toolchain/
dependencies/logs/outputs/helper, отсутствие/failed receipt и restart/verify с
certificate proof + старыми тестами + новыми build receipts. Генерация APK/image
в этом regression-тесте подменена; это не настоящая сборка или подпись.
Сравнение AST подтвердило прежние рецепты, signing/APK/gates/finalize и stage
execution. В build изменён только более строгий допуск полного PASS набора.
Файлы PSI/cgroup синтетические; настоящий HP OOM этим не воспроизводился.
CI нового HEAD публикуется отдельно в PR9; исторические PASS не переносятся.

Ранее проверка config: 14 адресных тестов PASS на временном Git с подменёнными
внешними сервисами. Покрыты uppercase/lowercase colon pin, неверный сертификат,
другие поля и типы JSON (включая `true` → `1`), изменённый backup, отсутствие,
чужой UID, 0644, symlink, неподготовленный checkpoint, прерванный merge,
повторная проверка proof, неизменность файлов `--check`, resume/reuse receipt
после успешного этапа и отказ APK с другим сертификатом. Ещё 11 существующих
адресных регрессий PASS: manifest history, stage/input/output integrity, read-only
inventory, resume/finalize и подпись/package APK. Внешние Docker/Android ответы
в этих тестах синтетические. Логика signing/APK, этапов, gates, merge, image,
save/snapshots и checksums не изменена (проверено сравнением AST с предыдущим HEAD).
Прежние CI результаты ниже/в PR остаются историческими; CI нового HEAD указывается
отдельно в PR, без переноса старых PASS на новый запуск.

Git overlap/resume, целостность истории и отказы проверяются на временном real Git.
Backend/API/migration content равен проверенному PR7; editor content равен PR6.
Объединённый Flutter/OpenAPI клиент проверяется отдельным адресным CI job.
Mocked Docker/Android tests не являются фактической сборкой. Реальные HP builder,
keystore, новый image/APK, Android/iOS, Synology и AI E2E — отдельная приёмка.
До реальной сборки и `apksigner verify` подписанный APK **не объявляется готовым**.
