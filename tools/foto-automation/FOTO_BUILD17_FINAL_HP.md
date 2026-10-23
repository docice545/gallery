# FOTO Build 17: продолжить остановленную сборку на HP

Это подготовка backend image и APK, **без deployment**. Запускает doctoriceadm.
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
FOTO_TOOLS_SHA=2b30c7620047b63e3a7cd193f4ef18600b2d44ff
FOTO_INSTALL=/usr/local/lib/foto-build17-release/$FOTO_TOOLS_SHA
FOTO_STAGE=$(mktemp -d /tmp/foto17-final-install.XXXXXXXX)
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
if sudo -u codex-gallery -H tmux -L foto17-final list-sessions >/dev/null 2>&1; then
  echo 'STOP: сессия foto17-final уже существует; подключитесь к ней, не запускайте вторую.' >&2
  exit 1
fi
for f in foto-build17-release foto-stage-runner.py foto-mobile-codegen.sh foto-android-build.sh foto-build17-release.example.json; do
  sudo -u codex-gallery -H gh api \
    "repos/docice545/gallery/contents/tools/foto-automation/$f?ref=$FOTO_TOOLS_SHA" \
    --jq .content | base64 --decode > "$FOTO_STAGE/$f"
done
cat > "$FOTO_STAGE/SHA256SUMS" <<'SHA256SUMS'
6452cbdcb58912971836bf031b813b823d15c3ba2d7d61d691201862a70caa89  foto-build17-release
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
FOTO_REPORT=$(mktemp /home/doctoriceadm/FOTO17-final-preflight.XXXXXXXX.txt)
foto_as_builder "$FOTO_INSTALL/foto-build17-release" \
  --config "$FOTO_RELEASE_CONFIG" --check > "$FOTO_REPORT" 2> "$FOTO_REPORT.stderr"
FOTO_SESSION=$(sudo -u codex-gallery -H mktemp -d /mnt/hp-data/codex-work/foto17-final-session.XXXXXXXX)
printf '%s\n' 'set-option -g remain-on-exit on' 'set-option -g history-limit 20000' | \
  sudo -u codex-gallery -H sh -c 'umask 077; cat > "$1"' sh "$FOTO_SESSION/tmux.conf"
foto_as_builder tmux -L foto17-final -f "$FOTO_SESSION/tmux.conf" \
  new-session -d -s foto17-final \
  "$FOTO_INSTALL/foto-build17-release" --config "$FOTO_RELEASE_CONFIG" --finalize
printf 'STARTED, не READY. Preflight: %s\n' "$FOTO_REPORT"
printf '%s\n' 'Ход/результат: sudo -u codex-gallery -H tmux -L foto17-final attach -t foto17-final'
BASH
```

`--check` — только inventory, даже exit0 не означает готовность к сборке.
`--finalize` сам повторяет gates и сначала проверяет существующие signing files.
Он держит common locks на всём пути prepare → test → build → verify.
Повторный запуск не повторяет прошедшие этапы, если совпадают SHA входов,
toolchain, журнала и outputs. Ошибка не запускает следующий этап или retry.

## Результат и повторное подключение

После обрыва SSH подключиться:

```bash
sudo -u codex-gallery -H tmux -L foto17-final attach -t foto17-final
```

Сессия сохраняет pane после выхода программы. Exit status:

```bash
sudo -u codex-gallery -H tmux -L foto17-final display-message -p -t foto17-final '#{pane_dead_status}'
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

## Что подтверждено и что ещё нет

Git overlap/resume, целостность истории и отказы проверяются на временном real Git.
Backend/API/migration content равен проверенному PR7; editor content равен PR6.
Объединённый Flutter/OpenAPI клиент проверяется отдельным адресным CI job.
Mocked Docker/Android tests не являются фактической сборкой. Реальные HP builder,
keystore, новый image/APK, Android/iOS, Synology и AI E2E — отдельная приёмка.
До реальной сборки и `apksigner verify` подписанный APK **не объявляется готовым**.
