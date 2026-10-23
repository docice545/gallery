# FOTO Build 17: продолжить остановленную сборку на HP

Это продолжение **уже подготовленного** backend image/APK release, **без deployment**.
Запускает doctoriceadm. Обновление исправляет вторую несовместимость Buildx v0.35.0:
JSON history содержит `status`, а не Go-template поле `.Status`. Ранее исправленный
текстовый inspect сохраняется. Старые установленные runners и их файлы сохраняются.

Оператор подтвердил checkpoint: `prepared=true`, `mode=prepare`, последнее событие
`PREPARED`, HEAD `e5883358c48a76a82fe7db29b5cd5ac0b1fc76e2`, тесты и сборки ещё
не запускались. Блок ниже проверяет именно это состояние, включая пустой список
этапов, и прекращает работу при отличии. Он не редактирует manifest/config,
не выполняет повторный merge PR6/PR7 и не сбрасывает подготовленный worktree.
Не запускайте Codex/другую сборку одновременно. Существующий config должен уже
содержать проверенные PR6/PR7 SHA, approvals и реальные пути старого ключа и
key.properties с доверенным fingerprint сертификата. Ключи/пароли не копируются
и не публикуются. Подтверждённый оператором прежний config:
`/mnt/hp-data/codex-home/foto-build17-release-check-0bd44fb68.json`.
Инструкция использует его без изменения и не создаёт заменяющий config/state.

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
FOTO_TOOLS_SHA=6a948e3fe6cf9d80d1e65e171c28ca0c90024893
FOTO_INSTALL=/usr/local/lib/foto-build17-release/$FOTO_TOOLS_SHA
FOTO_STAGE=$(mktemp -d /tmp/foto17-buildx035-history-install.XXXXXXXX)
FOTO_RELEASE_CONFIG=/mnt/hp-data/codex-home/foto-build17-release-check-0bd44fb68.json
[[ "$FOTO_RELEASE_CONFIG" = /* ]]
sudo -u codex-gallery -H test -f "$FOTO_RELEASE_CONFIG"
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
if sudo -u codex-gallery -H tmux -L foto17-buildx035-history list-sessions >/dev/null 2>&1; then
  echo 'STOP: сессия foto17-buildx035-history уже существует; подключитесь к ней, не запускайте вторую.' >&2
  exit 1
fi
for f in foto-build17-release foto-stage-runner.py foto-mobile-codegen.sh foto-android-build.sh foto-build17-release.example.json; do
  sudo -u codex-gallery -H gh api \
    "repos/docice545/gallery/contents/tools/foto-automation/$f?ref=$FOTO_TOOLS_SHA" \
    --jq .content | base64 --decode > "$FOTO_STAGE/$f"
done
cat > "$FOTO_STAGE/SHA256SUMS" <<'SHA256SUMS'
90b0ac3488f19fc5a754d87d2aee26ff89b47a81ade0909cd4bee87922101287  foto-build17-release
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
if not (state.get('prepared') is True and state.get('mode') == 'prepare'
        and state.get('head') == expected and state.get('stages') == {}
        and state.get('history') and state['history'][-1].get('event') == 'PREPARED'):
    raise SystemExit('STOP: checkpoint differs from confirmed PREPARED state; nothing reset')
head = subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null', '-C', state['worktree'],
                                'rev-parse', 'HEAD'], text=True).strip()
if head != expected:
    raise SystemExit('STOP: prepared worktree HEAD differs; nothing reset')
print(hashlib.sha256(raw).hexdigest())
PY_CHECKPOINT
}
FOTO_CHECKPOINT_BEFORE=$(foto_checkpoint)
FOTO_REPORT=$(mktemp /home/doctoriceadm/FOTO17-final-preflight.XXXXXXXX.txt)
foto_as_builder "$FOTO_INSTALL/foto-build17-release" \
  --config "$FOTO_RELEASE_CONFIG" --check > "$FOTO_REPORT" 2> "$FOTO_REPORT.stderr"
python3 - "$FOTO_REPORT" <<'PY_VALIDATION'
import json, pathlib, sys
report = json.loads(pathlib.Path(sys.argv[1]).read_text())
if report.get('docker', {}).get('builderValidation') != 'PASS_READ_ONLY_LIMITS_AND_IDLE':
    raise SystemExit('STOP: builderValidation is not PASS; inspect the private preflight report')
print('PASS builderValidation=PASS_READ_ONLY_LIMITS_AND_IDLE')
PY_VALIDATION
[[ "$(foto_checkpoint)" = "$FOTO_CHECKPOINT_BEFORE" ]] || {
  echo 'STOP: checkpoint changed during check; nothing reset' >&2
  exit 1
}
FOTO_SESSION=$(sudo -u codex-gallery -H mktemp -d /mnt/hp-data/codex-work/foto17-buildx035-history-session.XXXXXXXX)
printf '%s\n' 'set-option -g remain-on-exit on' 'set-option -g history-limit 20000' | \
  sudo -u codex-gallery -H sh -c 'umask 077; cat > "$1"' sh "$FOTO_SESSION/tmux.conf"
foto_as_builder tmux -L foto17-buildx035-history -f "$FOTO_SESSION/tmux.conf" \
  new-session -d -s foto17-buildx035-history \
  "$FOTO_INSTALL/foto-build17-release" --config "$FOTO_RELEASE_CONFIG" --finalize
printf 'STARTED, не READY. Preflight: %s\n' "$FOTO_REPORT"
printf '%s\n' 'Ход/результат: sudo -u codex-gallery -H tmux -L foto17-buildx035-history attach -t foto17-buildx035-history'
BASH
```

`--check` — только inventory, даже exit0 не означает готовность к сборке.
`--finalize` сам повторяет gates и сначала проверяет существующие signing files.
Для уже подготовленного checkpoint `prepare()` только проверяет целостность и
возвращается **без fetch/merge**. Затем впервые запускаются тесты и сборки.
Обычный `--resume` при сохранённом `mode=prepare` не запускает следующие этапы,
поэтому здесь выбран явный `--finalize`. SHA runner впервые фиксируется в
квитанциях тестов; их пока нет. Формат manifest/checkpoint и проверки квитанций
не изменены; уже выполненная интеграция сохраняется.
Он держит common locks на всём пути prepare → test → build → verify.
Повторный запуск не повторяет прошедшие этапы, если совпадают SHA входов,
toolchain, журнала и outputs. Ошибка не запускает следующий этап или retry.

## Результат и повторное подключение

После обрыва SSH подключиться:

```bash
sudo -u codex-gallery -H tmux -L foto17-buildx035-history attach -t foto17-buildx035-history
```

Сессия сохраняет pane после выхода программы. Exit status:

```bash
sudo -u codex-gallery -H tmux -L foto17-buildx035-history display-message -p -t foto17-buildx035-history '#{pane_dead_status}'
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

## Если сборка остановилась

- Снова `PARTIALLY_APPLIED_PR_REVIEW_REQUIRED`: HEAD/base/frontier не совпали с
  reviewed набором. Ничего не reset/clean и не редактировать manifest.
- `REVIEWED_OVERLAP_TREE_DIFFERS...` / `REVIEWED_MERGE_RESULT_DIFFERS...`:
  неизвестный результат Git; worktree и intent сохранены, нужна отдельная проверка.
- `MERGE_INTERRUPTED...`: реальный merge был прерван; этот patch не разрешает
  автоматически чинить его. Не удалять MERGE_HEAD/checkpoint.
- `CONFIG_CHANGED_USE_NEW_STATE` / `STAGE_INPUT_CHANGED_NEW_STATE_REQUIRED`:
  старые receipts принадлежат другим входам. Сохранить state; не подменять hashes.
- `MISSING_TOOL_*` / JDK / signing error: исправить только указанную существующую
  toolchain/config после локальной проверки. Новый ключ создавать запрещено.
- OOM137/DeadlineExceeded: сохранить logs и установить причину. Автоповторов нет;
  `--retry-failed --diagnosis` применяется только после реальной диагностики.

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

Git overlap/resume, целостность истории и отказы проверяются на временном real Git.
Backend/API/migration content равен проверенному PR7; editor content равен PR6.
Объединённый Flutter/OpenAPI клиент проверяется отдельным адресным CI job.
Mocked Docker/Android tests не являются фактической сборкой. Реальные HP builder,
keystore, новый image/APK, Android/iOS, Synology и AI E2E — отдельная приёмка.
До реальной сборки и `apksigner verify` подписанный APK **не объявляется готовым**.
