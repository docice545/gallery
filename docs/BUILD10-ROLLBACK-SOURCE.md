# Build 10: продолжение после REVIEWED_ROLLBACK_SOURCE_REQUIRED

Цель обновления остаётся `ea51a8acdc6f18ab5917c19b6f3833d740b4e9ba`, образ
`sha256:4d4f9d581a654713b6d305f9aa1341b302fd36fc4ef7fca832dcb94de4004e75`.
Его не пересобирать. Production image
`sha256:828523317c332cb312246c9b0ca43e0eef1eb724f7f9aadb58c61b7f87068f43`
имеет пустой `IMMICH_SOURCE_COMMIT`. По доступным данным его source не доказан.
Передать предположительный SHA через CLI недостаточно: `probe_image()` проверяет
реальный baked source, шесть compiled guard-файлов и полную migration inventory.
Старый image не выбран в качестве проверенного rollback; его не изменять/retag.

## Проверенный отдельный fallback

- Application source: `81867689be4d773473b6a3f417eee16c0329231e`.
- Build tooling: `cfc1ea532cf7926a4dddea5e4d73a15d0ca364ef` (только поправка CI
  smoke к существующему ответу `scope: managed`, без изменения application inputs).
- CI: <https://github.com/docice545/gallery/actions/runs/38166908087>, SUCCESS.
- Artifact: `gallery-trash-server-linux-amd64`, ID `11712627739`.
- ZIP SHA-256: `48527713b211b8c66a41f78dc7677bb9cff06afc952bc1cb53d6b61b80299329`.
- Docker archive SHA-256:
  `d0e9e46997df44e6fe5bcb614608672b7e3bec3a6ab8667f440583337f27a45a`.
- CI image ID:
  `sha256:0f9e791e36ce747a02b53827122e514277b0195ef2ec43e64d2b7eaaa0238ab2`.
- Version: 5.7.3 (mobile build metadata 10; мобильные приложения не пересобирались).

Это ограниченный rollback нового cross-owner administrator API: отсутствуют два
`assets/admin/*-deletion-preparation` endpoint из ea51. Собственная administrator
preparation, индивидуальное согласие/revoke владельца, Trash/Restore, permanent
deletion и все security guards сохранены. Подготовка за другого владельца будет
недоступна **только при rollback**; основной target ea51 предоставляет её.
Это не реконструкция неизвестного старого HP source и не просто смена metadata.

В отдельной cloud compilation все шесть compiled guard-файлов и все 170
compiled migrations побайтово совпали с ea51; 465 backend-тестов PASS. CI проверил
реальные Docker build/export, свежую disposable PostgreSQL/Redis, HTTP
Trash/Restore, отказ без policy, signed lab preparation, owner consent,
permanent deletion, receipt и запрет reimport. Synthetic CI recovery не доказывает
восстановимость production. Скачивание ZIP в Web Codex отклонено сетевым фильтром;
проверка конкретного архива и импорт на HP остаются обязательным preflight.

## Одна HP-сессия

Пользователь `doctoriceadm`; существующий RUN_ROOT сохраняется:
`/home/doctoriceadm/gallery-build10-release-TxDlXAuj`.
Нужны Python 3.11+, tmux, curl, sha256sum, действующий Docker Compose,
`sudo docker` и существующая авторизация GitHub CLI для скачивания artifact.
Если `gh` у doctoriceadm не авторизован, скачать **этот** artifact через GitHub
UI, сохранить ZIP как `RUN_ROOT/hardened-rollback-11712627739.zip`, установить
права 0600. Сценарий проверит закреплённый ZIP SHA; новые tokens/keys не создаются.
Artifact хранится GitHub Actions 14 дней. Истёкший/недоступный artifact — STOP,
не повод заменить checksum или выбрать другой image.

Сохранить свежий PostgreSQL backup с проверенным isolated restore и реальную NAS
recovery evidence до применения. Receipt для другого backup не подходит.
Сценарий не создаёт/не подменяет recovery evidence, не включает consent или retention.

Взять full tooling commit и SHA checksum manifest из итогового handoff:

```bash
set -euo pipefail
umask 077
test "$(id -un)" = doctoriceadm
RUN_ROOT=/home/doctoriceadm/gallery-build10-release-TxDlXAuj
: "${TOOLING_COMMIT:?Full published tooling commit from handoff}"
: "${MANIFEST_SHA256:?Checksum manifest SHA-256 from handoff}"
TOOLS="$RUN_ROOT/rollback-tooling-${TOOLING_COMMIT:0:12}"
test -d "$RUN_ROOT"
test ! -L "$RUN_ROOT"
test "$(stat -c %a "$RUN_ROOT")" = 700
test "$(stat -c %u "$RUN_ROOT")" = "$(id -u)"
command -v tmux >/dev/null
if [ ! -e "$TOOLS" ]; then mkdir -m 700 "$TOOLS"; fi
test ! -L "$TOOLS"
test "$(stat -c %a "$TOOLS")" = 700
test "$(stat -c %u "$TOOLS")" = "$(id -u)"
BASE="https://raw.githubusercontent.com/docice545/gallery/$TOOLING_COMMIT/scripts/release"
MANIFEST="$TOOLS/build10-rollback-tooling.sha256"
if [ ! -e "$MANIFEST" ]; then
  curl --fail --silent --show-error --location "$BASE/build10-rollback-tooling.sha256" --output "$MANIFEST"
fi
test ! -L "$MANIFEST"
printf '%s  %s\n' "$MANIFEST_SHA256" "$MANIFEST" | sha256sum --check --strict
for file in hp_build10_rollback.py hp_build10_rollback.sh image_release.py trash_image_identity.py trash_release.py trash_predeploy.py; do
  if [ ! -e "$TOOLS/$file" ]; then
    curl --fail --silent --show-error --location "$BASE/$file" --output "$TOOLS/$file"
  fi
  test ! -L "$TOOLS/$file"
done
(cd "$TOOLS"; sha256sum --check --strict build10-rollback-tooling.sha256)
bash -n "$TOOLS/hp_build10_rollback.sh"
SESSION=gallery-build10-rollback-TxDlXAuj
if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux attach-session -t "$SESSION"
else
  tmux new-session -s "$SESSION" bash -c 'sudo -v && bash "$1/hp_build10_rollback.sh" continue "$2"; result=$?; printf "SESSION_RESULT=%s\n" "$result"; exec bash' _ "$TOOLS" "$RUN_ROOT"
fi
```

Операторский approval — отдельный финальный шаг: ввести **`apply ea51a8ac`**
только после PASS и проверки backup prerequisites/ограниченного rollback scope.
До этой фразы происходят только чтение production и загрузка отдельного
fallback image в локальный image store. Сервисы не пересоздаются.

## Fail-closed проверки и результат

`hp_build10_rollback.py` использует неизменённый `image_release.py` из 82ac.
ZIP закреплён по CI digest. Existing `trash_image_identity.py` проверяет streaming
SHA всех config/layer bytes и OCI descriptor graph; Docker load/save identity
проверяется независимо от различия config digest и containerd manifest digest.
Тег не перезаписывается, если он занят другим образом.

Новый plan создаётся только в `RUN_ROOT/hardened-rollback/image-state`, прежний
failed `RUN_ROOT/state` не редактируется. Compose inputs/.env копируются 0600 в
отдельный backup; весь effective config должен отличаться только selected image.
Проверяются baked sources/version/platform, совпадение шести actual guards и всей
migration inventory, API и microservices, live PostgreSQL migrations, recovery
binds и identities всех остальных containers, включая inpainting. Pending
migrations — STOP с отдельным backup/migration approval; wrapper их не разрешает.
Очереди проверяются atomic LLEN/ZCARD всех семи состояний и bounded legacy
inventory, повторно непосредственно перед update. SCAN не доказывает пустоту.
Jobs не очищаются, не приостанавливаются и не активируются. Непустая/неполная
инвентаризация — STOP; образ не обновляется.

После approval: только `immich-server`, `up -d --no-deps --no-build --pull never`;
источники Compose, volumes/mounts/networks/env и unrelated services сохраняются.
Не используются force-recreate, down, remove-orphans, prune или восстановление
SQL поверх живого DB. `applied.json` подтверждает image/source/version/API health;
disposable thumbnail/preview job надо отдельно проверить на HP после deployment.
Вывод настроек workers сам по себе не доказывает выполнение thumbnail job.

Каждый вызов имеет приватный journal и `RESULT exit=...`. При SSH disconnect
повторить этот блок: existing tmux session будет подключена без повторного build,
download или deployment. После попытки без completion receipt не повторять
apply; сохранить journal. При failed prepare каталог не перезаписывается.

## Отдельно подтверждаемый rollback

В существующей tmux-сессии (TOOLS/RUN_ROOT можно определить теми же значениями):

```bash
sudo -v
bash "$TOOLS/hp_build10_rollback.sh" rollback "$RUN_ROOT"
# Отдельное подтверждение: rollback ea51a8ac
```

Rollback проверяет уже запланированный image/guards/migrations и поддерживает
остановленный failed API. Остальные сервисы не пересоздаются. Он не возвращает
удалённые оригиналы и не отменяет receipts/tombstones/consent. После любого
recreation mount namespace меняется: новые подписанные recovery proofs для
каждого owner/scope и индивидуальный consent выпускаются штатным процессом
[SYNOLOGY-RECOVERY-EVIDENCE.md](SYNOLOGY-RECOVERY-EVIDENCE.md).
Не мигрировать 291 offline index tombstones. Retention остаётся отдельным approval.
