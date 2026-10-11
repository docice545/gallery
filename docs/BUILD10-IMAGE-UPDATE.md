# HP: обновление готового Gallery 5.7.3 (10), ea51a8ac

Application source остаётся `ea51a8acdc6f18ab5917c19b6f3833d740b4e9ba`.
Исправляется только tooling; повторная сборка backend/APK/IPA не требуется.
Все production-команды ниже выполняет владелец HP, не Web Codex.

## Почему возник STOP

В Docker Compose 2.40.3 `config --hash` вызывает `ToProject` с
`WithoutEnvironmentResolution`, а создание контейнера использует разрешённую
environment. При `env_file: .env` исходный хеш не включает значения этого файла.
Это воспроизведено настоящим Compose на отдельном Docker daemon, не HP.
Ссылки на upstream: [config.go](https://github.com/docker/compose/blob/v2.40.3/cmd/compose/config.go)
(`runHash`) и [hash.go](https://github.com/docker/compose/blob/v2.40.3/pkg/compose/hash.go)
(`ServiceHash`).

`image_release.py` теперь получает полную `config --format json`, передаёт её
через stdin тому же Compose и вычисляет тот же `ServiceHash`. Значения не
передаются через argv и не печатаются. Compose экранирует `$` в своём выводе;
повторное чтение снимает это экранирование, не раскрывая исходные переменные
ещё раз. `--no-interpolate` здесь неверен: он оставляет удвоенные доллары.

Три старых хеша не доказывают равенство фактической конфигурации HP.
Исправленный **resolved** хеш обязан точно совпасть с running label. Если нет,
STOP сохраняется; сообщение содержит только два хеша. Никакого fallback,
подстановки label вместо вычисления или `--allow-drift` нет. Файлы берутся
только из реальных Compose labels контейнера, в исходном порядке. Recovery
override не добавляется и не удаляется наугад.

Проверки image-only effective config, worker environment, локальной БД,
образов, миграций и всех остальных контейнеров сохранены. Новые image volume
defaults не могут создать незапланированное хранилище. План сохраняет режим
расчёта хеша; старые состояния нельзя применять новым инструментом. Их не
редактировать и не удалять: создать новый приватный release directory.

## Перед применением

- Готовый загруженный target:
  `sha256:4d4f9d581a654713b6d305f9aa1341b302fd36fc4ef7fca832dcb94de4004e75`.
  Проверенные артефакты `/mnt/hp-data/gallery-release-ea51a8ac/build/` сохраняются.
- Ожидаемый текущий image:
  `sha256:828523317c332cb312246c9b0ca43e0eef1eb724f7f9aadb58c61b7f87068f43`.
- Рабочий PostgreSQL backup с проверенным восстановлением, сохранённые recovery
  reports и реальные снимки Synology. Старый receipt не доказывает восстановимость
  другого нового backup. Эта процедура их не создаёт и не подменяет.
- Rollback image уже присутствует локально, содержит проверенные hardened guards
  и ту же compiled migration inventory. По умолчанию проверяется текущий image.
  **Существующий guard требует одинаковые bytes всех шести deletion modules.**
  Если предыдущая сборка отличается, `HARDENED_ROLLBACK_GUARD_FILES_MUST_MATCH`
  остаётся hard STOP; одно совпадение версии/marker недостаточно. Нужен отдельно
  проверенный совместимый rollback image и стандартный `image_release.py plan`
  с его `--rollback-image`, `--rollback-source-commit`, `--rollback-server-version`.
  Обёртка не создаёт и не маскирует такой образ.
- При pending migrations эта короткая обёртка останавливается. Требуется отдельный
  approved backup/migration workflow; автоматического `--approve-migration` нет.
- API и microservices работают вместе. Никакие include/exclude переменные не
  добавляются. Inpainting, Memories, ML, Redis, PostgreSQL, mounts и networks
  сохраняются. Не запускать down, remove-orphans, prune или force-recreate.

## Один приватный операторский сеанс

Взять точный **tooling commit** и checksum manifest SHA-256 из handoff.
Не использовать floating branch URL. Нужны существующие `tmux`, Python 3.11+,
Docker Compose и разрешение `sudo -n docker`. Никаких установок или новых keys.

```bash
set -euo pipefail
umask 077
command -v tmux >/dev/null
RUN_ROOT="$(mktemp -d /home/doctoriceadm/gallery-build10-release-XXXXXXXX)"
mkdir -m 700 "$RUN_ROOT/tooling"
: "${TOOLING_COMMIT:?Exact reviewed tooling commit from handoff}"
: "${MANIFEST_SHA256:?Exact tooling manifest SHA-256 from handoff}"
BASE_URL="https://raw.githubusercontent.com/docice545/gallery/$TOOLING_COMMIT/scripts/release"
curl --fail --silent --show-error --location "$BASE_URL/build10-image-tooling.sha256" \
  --output "$RUN_ROOT/tooling/build10-image-tooling.sha256"
printf '%s  %s\n' "$MANIFEST_SHA256" "$RUN_ROOT/tooling/build10-image-tooling.sha256" | sha256sum --check --strict
for file in image_release.py hp_build10_image_update.sh trash_release.py trash_predeploy.py; do
  curl --fail --silent --show-error --location "$BASE_URL/$file" --output "$RUN_ROOT/tooling/$file"
done
(cd "$RUN_ROOT/tooling"; sha256sum --check --strict build10-image-tooling.sha256)
bash -n "$RUN_ROOT/tooling/hp_build10_image_update.sh"
chmod 700 "$RUN_ROOT/tooling/hp_build10_image_update.sh"
printf 'RUN_ROOT=%s\n' "$RUN_ROOT"
tmux new-session -s "gallery-build10-${RUN_ROOT##*-}" -e "RUN_ROOT=$RUN_ROOT"
```

Внутри tmux `RUN_ROOT` уже установлен. Выполнить цепочку ниже; при любом STOP
следующая команда не запускается:

```bash
sudo -v
"$RUN_ROOT/tooling/hp_build10_image_update.sh" plan "$RUN_ROOT" &&
  "$RUN_ROOT/tooling/hp_build10_image_update.sh" apply "$RUN_ROOT" &&
  "$RUN_ROOT/tooling/hp_build10_image_update.sh" status "$RUN_ROOT"
# Для подтверждения ввести ровно: apply ea51a8ac
# Выполнять только после PASS и выполнения backup prerequisites:
sudo -n docker --host=unix:///var/run/docker.sock inspect \
  --format '{{.Image}} {{.State.Health.Status}}' immich_server
```

`plan` не меняет контейнеры. Он сохраняет private plan и побайтовые backups
Compose inputs/.env в `compose-input-backups/` (0600), затем делает dry-run
preflight. Каждый вызов имеет отдельный private journal и конечный `RESULT
exit=...`. Каталог всего сеанса 0700, никаких chmod/chown всего `/mnt/hp-data`.
Новый `state/` создаётся один раз; не использовать прежний failed directory.
Сохранить весь `RUN_ROOT`: running Compose labels после update ссылаются на
находящийся там image-only override. Его удаление заблокирует следующий plan.

`apply` повторяет preflight, требует указанную фразу и вызывает существующий
helper с отдельным deployment approval. Очереди перепроверяются существующим
bounded collector непосредственно перед update: atomic LLEN/ZCARD всех семи
состояний до/после инвентаризации и незавершённые AssetDelete/FileDelete hashes.
SCAN сам по себе не доказывает пустоту. Это observation в данный момент, не pause.
Непустая/неполная очередь блокирует update; jobs не очищаются и не запускаются.

Обновление — только `immich-server` через `up -d --no-deps --no-build --pull never`.
Проверяются healthy, source/version/image, API, оба worker settings, migrations,
весь effective config и identities всех остальных контейнеров, включая orphan
inpainting. Receipts `applied.json`/`rolled-back.json` — доказательство завершения,
не обещание текущего health навсегда. `status` честно различает planned/unfinished.

При обрыве SSH: подключиться повторно, `tmux ls`, `tmux attach -t <session>`.
Никогда не повторять apply после наличия `apply-attempt.json`. Сначала status/log.

## Rollback

Без очистки DB, восстановления старого SQL поверх живого состояния или удаления
томов, в том же tmux и с тем же `RUN_ROOT`:

```bash
"$RUN_ROOT/tooling/hp_build10_image_update.sh" rollback "$RUN_ROOT" &&
  "$RUN_ROOT/tooling/hp_build10_image_update.sh" status "$RUN_ROOT"
# Для отдельного подтверждения ввести: rollback ea51a8ac
```

Helper проверяет запланированный hardened rollback target до изменения service,
поддерживает остановленный failed API container и не требует exec в нём для
rollback. PostgreSQL migration evidence читается из существующего PostgreSQL.
Compose sources должны оставаться прежними; backups не накладываются автоматически.
Гарантии image-only и сохранения других services действуют и на rollback. При
STOP сохранить logs/plan, не обходить защиту вручную.

Rollback образа не возвращает уже удалённые оригиналы, не отменяет consent и не
удаляет receipts/tombstones. Восстановление медиа требует отдельного реального
snapshot recovery; не удалять recovery evidence и не включать retention.

## После обновления: отдельные proofs и согласие каждого владельца

1. Проверить один новый **disposable** upload: thumbnail + preview, просмотр в
   Android/web, обработка background jobs. Verify both API/microservices logs;
   setting check alone не доказывает выполнение thumbnail job.
2. Сохранённые RO public-key/evidence binds из recovery override должны остаться.
   Private Ed25519 key остаётся на HP вне контейнера. Если binds фактически не
   присутствуют, это отдельное reviewed изменение конфигурации, не скрытый bypass.
3. После recreation заново выполнить `trash_recovery_inputs.py capture` для
   **каждого owner/scope**. Mount namespace изменился: старые policies/proofs не
   переименовывать и не обновлять даты искусственно. Для каждой из трёх внешних
   libraries использовать её UUID и действительного owner; managed — scope `managed`
   того же индивидуального владельца и его реальные upload/library roots.
4. Выполнить фактический экспорт photo/video из реального проверенного snapshot
   соответствующего хранилища, hash/size сравнение и `prepare`, затем существующий
   `trash_recovery_evidence.py`. Требуются verified PG restore receipt и точные bytes
   backup, per-root snapshot provenance и свежие восстановленные samples. Подпись
   Ed25519 связывает owner/scope/root identity; срок не более 24 часов. Процедура и
   полные команды: [SYNOLOGY-RECOVERY-EVIDENCE.md](SYNOLOGY-RECOVERY-EVIDENCE.md).
   Managed HP storage требует доказанного recovery именно своих roots; Synology
   snapshot другой external library этого не доказывает. Нельзя выдать proof
   для отсутствующего snapshot, другого owner или неподтверждённого recovery.
5. Опубликовать подписанные envelopes в существующий RO evidence store штатным
   `publish` после отдельного разрешения. Вызвать от **администратора** один из API:

   ```text
   PUT /api/assets/admin/managed-deletion-preparation
   PUT /api/assets/admin/library-deletion-preparation/<exact library UUID>
   Body: {"ownerId":"<actual UUID>","recoveryProof":"<signed envelope digest>","verifiedExclusiveRoots":true}
   ```

   Используется существующая administrator session/API key с `systemConfig.update`.
   Roots выводятся на сервере; подготовка всегда `enabled=false`. Никаких новых
   accounts/API keys, SQL updates, NAS permissions или admin consent за другого owner.

6. **Каждый владелец** входит в свой существующий Android Build 10/web account,
   открывает Trash → «Разрешение окончательного удаления» для managed или
   «Разрешение удаления из внешней библиотеки» → конкретная library → разрешить →
   подтверждение. Owner consent APIs остаются `managed-deletion-consent` и
   `library-deletion-consent/<UUID>` с `enabled:true, confirmed:true`.
   Managed consent не включает external; library consent не включает другой owner,
   другую library или автоматическую retention. Отзыв: `enabled:false, confirmed:true`.
7. Проверить soft-delete → restore → selective permanent deletion на **одном
   специально созданном disposable asset** в каждой разрешаемой scope; NAS/NFS
   mutation tests — только с отдельным разрешением на этот disposable asset.
   Проверить реальное исчезновение только его файла, receipt, timeline и
   неизменность чужих originals. Не применять Empty Trash к семейным данным
   как smoke test. Mixed scopes без полной authorization должны блокироваться.

291 offline external index tombstones не мигрируются, не отображаются как user
Trash и не удаляются. Окончательное удаление семейных originals и retention не
разрешаются фактом обновления образа. Production/device/NFS acceptance остаётся
операторским этапом; mock и cloud Docker проверки его не заменяют.
