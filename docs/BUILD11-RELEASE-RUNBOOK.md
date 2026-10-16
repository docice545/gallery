# Gallery 5.7.3 (11): установка, обновление HP и откат

Этот документ относится к собранному пакету Build 11. На 2026-10-16 read-only
audit зафиксировал фактический production image
`sha256:52e08a50b507ddddf591706eed8df70c1904b47fca53d5e913146853df2a2b8b` и
кандидат `sha256:1b6ee28e2b868280a9787cef5533636736de1148a18d2915ca5ff42835362bef`
(source `8af3a7a923c1391474dc9b7410e2f7833bc7771d`). Эти значения являются
текущими входами для read-only plan; они не являются разрешением deployment.

Не подставляйте старые image IDs, source commit или результаты восстановления.
Пока не получен настоящий pinned reviewed-compatibility receipt, выпуск
**не готов к установке**.

Пакет содержит backend с web и API/microservices, APK, unsigned IPA,
контрольные суммы, конфигурацию и четыре операторских скрипта. HP не должен
компилировать исходники. Подпись Android выполняется отдельно существующим ключом;
подпись iOS выполняется через прежний SideStore.

## Что меняется при обновлении HP

Обновляется только образ сервиса `immich-server` проекта `immich` в `/opt/immich`.
Добавляется обратимо совместимый столбец `authorizationMode`; старые поля,
идентификаторы, владельцы, метаданные, Trash timestamps и migration ledger
сохраняются. Приложение само применяет проверенную миграцию при запуске;
ручные SQL-команды и сброс схемы не требуются.

PostgreSQL, Redis, ML, inpainting, Memories, NFS mounts, Docker volumes/networks,
VPN, DNS и прокси не изменяются. API и microservices должны работать оба.
API-only конфигурация отклоняется. Запрещены `down -v`, удаление orphan-контейнеров,
глобальная очистка Docker/Redis и массовое изменение прав на SSD/NAS.

Ожидается краткая недоступность Gallery во время запуска нового server; точное
время определяется размером БД и health checks. Нельзя обещать нулевой downtime.
Свежий audit сообщает 1389 объектов в корзине, 14 backup-файлов, пустые deletion
queues в момент read-only снимка и `BackgroundTask paused=false`; это не доказывает
безопасность переключения. Перед любым apply очередь нужно отдельно pause-нуть,
дождаться `active=0`, повторно проверить все семь состояний и сохранить текущие
deletion intents. Нельзя clean/drain/kill/retry jobs или автоматически resume.

## Необходимые условия

Для HP: оператор `doctoriceadm`, Python 3.11+, Docker с Compose v2, `tmux`,
`curl`, `sha256sum`, существующее право `sudo docker`; пароль вводится только в
обычном `sudo -v`. Скрипты не получают права сами и не устанавливают пакеты.
Публичные зависимости clean install загружаются только по неизменяемым digest.

Нужны свежий SQL/gzip backup, проверка восстановления именно этого backup в
изолированный PostgreSQL и реальные NAS recovery evidence не старше 24 часов.
При подготовке свежий backup и его restore создаются автоматически. Старый
PG PASS не удостоверяет новый backup. NAS evidence нельзя обновлять переписыванием
`verifiedAt`: новые отметки допускаются только после настоящей проверки файлов
из подтверждённого snapshot.

Диск: подготовка требует свободного места не менее `max(2 × размер БД, 2 GiB)`
для backup и дополнительного места для Docker images, временной восстановленной
БД и бинарного пакета. Нехватка места — STOP до изменения server. Backup/rollback
не удаляются после успешной установки. Внешние NFS-корни должны существовать с
прежними source/target/options; mount drift останавливает операцию.

## Проверить скачанный пакет

В release handoff получите настоящий URL пакета и SHA-256 его `SHA256SUMS`.
Распакуйте готовый пакет в `/mnt/hp-data/gallery-build11-package`. В каталог нельзя
добавлять незаявленные исполняемые файлы. Следующий блок ничего не разворачивает:

```bash
set -euo pipefail
umask 077
test "$(id -un)" = doctoriceadm
PACKAGE=/mnt/hp-data/gallery-build11-package
: "${BUILD11_SHA256SUMS_SHA256:?Укажите опубликованный SHA-256 SHA256SUMS}"
printf '%s  %s\n' "$BUILD11_SHA256SUMS_SHA256" "$PACKAGE/SHA256SUMS" | sha256sum -c --strict -
(cd "$PACKAGE" && sha256sum -c --strict SHA256SUMS)
python3 -B "$PACKAGE/tools/gallery_entry.py" --help >/dev/null
printf 'PASS пакет проверен; production не изменён\n'
```

## Текущий HP gate и compatibility receipt

Отчёт audit: `/home/doctoriceadm/gallery-trash-release-audit-20261016T041535554339Z-1aead3ec6751.txt`.
Он read-only, его live/non-atomic снимок не резервирует пустую очередь; backup
восстановлением не проверен. Поэтому этот этап имеет статус **BLOCKED**.

В доступных материалах нет настоящего `reviewed-compatibility.json`. Найденный
`build11-rollback-runtime.json` с SHA-256
`3b67e35a7337493e3b3ea9fd47853390e8dfa5cff2fbcc8eaa53a15d79903d96` не является
таким receipt и содержит `trashRestoreAfterRollback=false`. Image
`sha256:893281ae193f03c371227f0d9b11ebf74805709f39b296f7d2ecc241c7d5f65b` нельзя
считать rollback target до нового успешного runtime-теста и receipt. Нельзя
создавать JSON вручную или подменять `false` на `true`.

Receipt получают только существующим CI-инструментом
`scripts/release/build11_compatibility_receipt.py` из reviewed CI checkout на
disposable runner. Нужны четыре
различных успешных same-source run/artifact: candidate backend, Android, iOS и
отдельный rollback. Инструмент сам проверяет actual image probes, migration/guard
bytes, rollback archive identity и isolated HTTP/Trash/Restore report; при
`trashRestoreAfterRollback=false` он должен завершиться STOP. После получения
receipt сохраните его append-only и передайте его SHA-256 в plan:

```bash
set -euo pipefail
export GITHUB_ACTIONS=true GALLERY_DISPOSABLE_RELEASE_TESTS=1
CI_ROOT=/path/to/reviewed-ci-checkout
ARTIFACTS=/path/to/candidate-artifacts
ROLLBACK_ARTIFACTS=/path/to/reviewed-rollback-artifacts
PROFILE=/path/to/candidate-profile.json
OUT=/path/to/new/reviewed-compatibility.json
: "${CANDIDATE_PROFILE_SHA256:?SHA-256 candidate profile from handoff}"
: "${ROLLBACK_SOURCE_SHA:?40-hex rollback source}"
: "${ROLLBACK_RUN:?successful rollback CI run ID}"
python3 -B "$CI_ROOT/scripts/release/build11_compatibility_receipt.py" build \
  --artifacts "$ARTIFACTS" --rollback-artifacts "$ROLLBACK_ARTIFACTS" \
  --profile "$PROFILE" --profile-sha256 "$CANDIDATE_PROFILE_SHA256" \
  --rollback-source "$ROLLBACK_SOURCE_SHA" --rollback-run "$ROLLBACK_RUN" \
  --output "$OUT"
sha256sum "$OUT"
```

Это не выполняется на HP и не заменяет production backup/queue gate. Успешный
receipt должен содержать candidate image
`sha256:1b6ee28e2b868280a9787cef5533636736de1148a18d2915ca5ff42835362bef`; его
rollback image и source берутся только из самого receipt/rollback manifest.

## Единый безопасный HP preflight

После появления проверенного пакета один скрипт выполняет все доступные проверки:
sealed intents, свежий read-only audit, compatibility/image gate и существующий
isolated backup/restore. Он не вызывает `apply` или `rollback` и сохраняет единый
приватный JSON-отчёт в `STATE`. При отсутствии receipt или rootful Docker он
останавливается с точным `BLOCKED` кодом; receipt не создаётся.

```bash
set -euo pipefail
sudo -v
python3 -B /opt/gallery-fork/scripts/release/build11_hp_preflight.py \
  --package /mnt/hp-data/gallery-build11-package \
  --state /home/doctoriceadm/gallery-build11-preflight-20261016 \
  --previous-run-root /home/doctoriceadm/gallery-build10-release-TxDlXAuj \
  --nas-evidence "$BUILD11_NAS_EVIDENCE"
```

Если владелец отдельно разрешил pause, к той же команде добавляются
`GALLERY_QUEUE_PAUSE_APPROVED=YES` и `--pause-drain-key` с существующим файлом
режима `0600`. Без этого флага очередь не меняется, а незапаузированная очередь
оставляет итог `BLOCKED QUEUE_PAUSE_APPROVAL_REQUIRED`.

## Безопасная проверка intent и pause/drain

До apply оператор на HP должен read-only сверить сохранённые
`cleanup-intent-v1.json`, `cleanup-intent-seal-v1.json`, `file-proofs.json` и
завершённые `deletion-report-*.json` в существующем
`/home/doctoriceadm/gallery-build10-release-TxDlXAuj/queued-user-deletions/`.
Нельзя создавать новый intent, если старый отсутствует, и нельзя редактировать
его seal. Команда только проверяет наличие/права и хеши локальных файлов:

```bash
set -euo pipefail
RUN_ROOT=/home/doctoriceadm/gallery-build10-release-TxDlXAuj
PHASE="$RUN_ROOT/queued-user-deletions"
for file in cleanup-intent-v1.json cleanup-intent-seal-v1.json file-proofs.json; do
  test -f "$PHASE/$file" -a ! -L "$PHASE/$file"
  test "$(stat -c %a "$PHASE/$file")" = 600
done
sha256sum "$PHASE/cleanup-intent-v1.json" "$PHASE/cleanup-intent-seal-v1.json" "$PHASE/file-proofs.json"
find "$PHASE" -maxdepth 1 -type f -name 'deletion-report-*.json' -print | sort
```

После отдельного approval закрыть новые deletion mutations и вызвать штатный
admin API `PUT /api/jobs/backgroundTask` с `{"command":"pause"}`. Это единственная
операция pause; не использовать `isPaused`, Redis keys, `clean`, `drain`,
`obliterate`, `remove`, retry или kill. Пока очередь paused, ждать естественного
завершения active jobs и повторять существующий read-only audit. Продолжать можно
только при `paused=true`, `active=0`, `inventoryComplete=true`, нулевых
`AssetDelete`/`FileDelete` и сохранённых неизменных intent; при timeout, любом
UNKNOWN или новом job — STOP и оставить paused. Resume в этом этапе запрещён.

Подготовленная команда pause/drain (не выполнялась этим этапом) требует отдельного
approval и не печатает ключ:

```bash
set -euo pipefail
test "${GALLERY_QUEUE_PAUSE_APPROVED:-}" = YES
: "${ADMIN_API_KEY_FILE:?0600-файл существующего admin API key}"
test "$(stat -c %a "$ADMIN_API_KEY_FILE")" = 600
API=http://127.0.0.1:2283/api
KEY=$(cat "$ADMIN_API_KEY_FILE")
curl --fail --silent --show-error --noproxy '*' \
  -H "x-api-key: $KEY" -H 'content-type: application/json' \
  -X PUT "$API/jobs/backgroundTask" --data '{"command":"pause"}' >/dev/null
unset KEY
for attempt in $(seq 1 60); do
  output=$(python3 /opt/gallery-fork/scripts/diagnostics/hp_trash_release_audit.py 2>&1)
  report=$(printf '%s\n' "$output" | sed -n 's/^PASS private report created: //p')
  test -n "$report" -a -f "$report" || { echo STOP_AUDIT_REPORT_NOT_CREATED >&2; exit 1; }
  if python3 - "$report" <<'PY'
import json, sys
row = json.load(open(sys.argv[1]))
queue = row.get('backendReadOnlyAudit', {}).get('queue', {})
states = queue.get('states', {})
jobs = row.get('backendReadOnlyAudit', {}).get('deletionJobs', {})
if (queue.get('paused') is True and states.get('active') == 0 and
    queue.get('truncated') is False and jobs.get('inventoryComplete') is True and
    jobs.get('fileDelete') == 0 and jobs.get('legacyAssetDelete') == 0 and
    not row.get('backendReadOnlyAudit', {}).get('errors')):
    raise SystemExit(0)
raise SystemExit(1)
PY
  then
    echo 'PASS paused/drained deletion queue; keep it paused'
    break
  fi
  [ "$attempt" -lt 60 ] || { echo STOP_DELETION_QUEUE_DID_NOT_DRAIN >&2; exit 1; }
  sleep 5
done
```

Только после этих gates запускается `image_release.py plan`; production services,
PostgreSQL, Redis, NAS и media этим разделом не меняются.

## Текущий image-only plan (после всех gate)

Receipt обязан сам предоставить rollback image/source. До его появления команды
ниже намеренно останавливаются на обязательной переменной и ничего не меняют:

```bash
set -euo pipefail
umask 077
TOOL=/opt/gallery-fork/scripts/release/image_release.py
STATE=$(mktemp -d /home/doctoriceadm/gallery-image-release-20261016-XXXXXXXX)
: "${COMPATIBILITY_RECEIPT:?Путь к настоящему reviewed-compatibility.json}"
: "${COMPATIBILITY_SHA256:?SHA-256 этого receipt}"
: "${ROLLBACK_IMAGE:?rollbackImage из receipt}"
: "${ROLLBACK_SOURCE:?rollbackSource из receipt}"
: "${ROLLBACK_VERSION:?rollback server version из manifest}"
test "$(sha256sum "$COMPATIBILITY_RECEIPT" | awk '{print $1}')" = "$COMPATIBILITY_SHA256"
python3 -B "$TOOL" plan --sudo-docker --state "$STATE" \
  --image sha256:1b6ee28e2b868280a9787cef5533636736de1148a18d2915ca5ff42835362bef \
  --expected-current-image sha256:52e08a50b507ddddf591706eed8df70c1904b47fca53d5e913146853df2a2b8b \
  --source-commit 8af3a7a923c1391474dc9b7410e2f7833bc7771d --server-version 5.7.3 \
  --rollback-image "$ROLLBACK_IMAGE" --rollback-source-commit "$ROLLBACK_SOURCE" \
  --rollback-server-version "$ROLLBACK_VERSION" \
  --compatibility-receipt "$COMPATIBILITY_RECEIPT" --compatibility-sha256 "$COMPATIBILITY_SHA256"
python3 -B "$TOOL" apply --sudo-docker --state "$STATE"
```

Обе команды read-only. Только после отдельного deployment и additive-migration
approval, свежего paused/drained audit и успешного isolated backup/restore можно
запустить apply:

```bash
GALLERY_DEPLOYMENT_APPROVED=YES GALLERY_ADDITIVE_MIGRATION_APPROVED=YES \
python3 -B "$TOOL" apply --sudo-docker --state "$STATE" \
  --execute-approved --approve-migration
```

Точный rollback разрешается только с тем же `STATE` и receipt:

```bash
GALLERY_DEPLOYMENT_APPROVED=YES \
python3 -B "$TOOL" rollback --sudo-docker --state "$STATE" --execute-approved
```

Если apply создал `apply-attempt.json` или health check не прошёл, повторный apply
запрещён: сохранить state и выполнить только этот guarded rollback после pause и
`active=0`. Команда не восстанавливает удалённые originals и не перезапускает
PostgreSQL, Redis или ML.

## HP: подготовка до разрешения deployment

Используйте существующий RUN_ROOT
`/home/doctoriceadm/gallery-build10-release-TxDlXAuj`. Он содержит старые sealed
intent, file proofs и hardened rollback; не создавайте вместо него пустую копию.
Не предполагайте текущий image по тегу: plan обязан проверить фактический
`sha256:52e08a50b507ddddf591706eed8df70c1904b47fca53d5e913146853df2a2b8b`.

Укажите реальный каталог свежей NAS evidence в `BUILD11_NAS_EVIDENCE`, затем
выполните одну подготовительную команду. Это создаёт backup и isolated restore,
импортирует проверенные образы в локальный Docker cache и формирует план.
Работающие production services, очереди и оригиналы не изменяются:

```bash
set -euo pipefail
umask 077
test "$(id -un)" = doctoriceadm
PACKAGE=/mnt/hp-data/gallery-build11-package
OLD_RUN=/home/doctoriceadm/gallery-build10-release-TxDlXAuj
: "${BUILD11_SHA256SUMS_SHA256:?Нужен опубликованный checksum}"
: "${BUILD11_NAS_EVIDENCE:?Нужен настоящий свежий каталог NAS recovery evidence}"
printf '%s  %s\n' "$BUILD11_SHA256SUMS_SHA256" "$PACKAGE/SHA256SUMS" | sha256sum -c --strict -
(cd "$PACKAGE" && sha256sum -c --strict SHA256SUMS)
STATE=$(mktemp -d /home/doctoriceadm/gallery-build11-predeploy-XXXXXXXX)
printf 'PRIVATE_STATE=%s\n' "$STATE"
sudo -v
tmux new-session -s gallery-build11-prepare bash -c '
  set -uo pipefail; umask 077
  journal=$(mktemp "$2/preparation-XXXXXXXX.log")
  bash "$1/tools/gallery-upgrade.sh" prepare "$1" "$2" "$3" "$4" 2>&1 | tee "$journal"
  result=$?
  printf "RESULT exit=%s journal=%s\n" "$result" "$journal"
  exec bash
' _ "$PACKAGE" "$STATE" "$OLD_RUN" "$BUILD11_NAS_EVIDENCE"
```

Если текущий HP ещё не завершил Build 10 bridge, эта read-only подготовка
остановится с `COMPLETE_BUILD10_BRIDGE_FIRST` или требованием cleanup receipt.
Это не ошибка, которую нужно обходить. После отдельного разрешения шести
подтверждённых cleanup и image-only bridge используйте общий блок ниже с
`--complete-confirmed-cleanup`; он повторно проверяет старый sealed intent,
sandbox/RW mounts и отсутствие ссылок, не изобретая разрешение на NAS originals.

Отключение SSH не прекращает `tmux`. Возврат: `tmux attach -t
gallery-build11-prepare`. Сохраните выведенный `PRIVATE_STATE`: это единственный
каталог для check/apply/verify/rollback данного запуска. Нельзя менять receipt
или очищать state ради повторной попытки.

## HP: одна команда обновления после отдельного разрешения

Перед запуском владелец сервера должен одобрить конкретный Build 11, additive
migration и, если ещё требуется, старый exact-six bridge. Ни документация, ни
наличие файлов не считаются этим разрешением.

Задайте `STATE` из подготовки; если она остановилась до записи плана, после
устранения внешнего prerequisite используйте новый private state, сохранив старый.
В обычном upgrade-блоке ниже нет `--complete-confirmed-cleanup` и
`GALLERY_USER_QUEUED_DELETION_APPROVED`: этот этап не доказывает exact-six receipt
и не должен авторизовать удаление. Если `prepare` остановится с требованием
sealed cleanup receipt, это остаётся STOP, а не повод обходить guard.

```bash
set -euo pipefail
umask 077
test "$(id -un)" = doctoriceadm
PACKAGE=/mnt/hp-data/gallery-build11-package
OLD_RUN=/home/doctoriceadm/gallery-build10-release-TxDlXAuj
: "${STATE:?Укажите private state для этого запуска}"
: "${BUILD11_NAS_EVIDENCE:?Укажите проверенную свежую NAS evidence}"
: "${BUILD11_SHA256SUMS_SHA256:?Нужен опубликованный checksum}"
printf '%s  %s\n' "$BUILD11_SHA256SUMS_SHA256" "$PACKAGE/SHA256SUMS" | sha256sum -c --strict -
(cd "$PACKAGE" && sha256sum -c --strict SHA256SUMS)
sudo -v
tmux new-session -s gallery-build11-upgrade bash -c '
  set -uo pipefail; umask 077
  journal=$(mktemp "$2/upgrade-XXXXXXXX.log")
  GALLERY_DEPLOYMENT_APPROVED=YES GALLERY_ADDITIVE_MIGRATION_APPROVED=YES \
    bash "$1/tools/gallery-upgrade.sh" upgrade "$1" "$2" "$3" "$4" \
    --execute-approved --approve-migration 2>&1 | tee "$journal"
  result=$?
  printf "RESULT exit=%s journal=%s\n" "$result" "$journal"
  exec bash
' _ "$PACKAGE" "$STATE" "$OLD_RUN" "$BUILD11_NAS_EVIDENCE"
```

`upgrade` использует существующую подготовку либо запускает её один раз, затем
check → apply → status. Завершённый apply повторно не выполняется: проверяется
его receipt и фактический image/source/API. При незавершённом apply автоматически
повторять command нельзя; сохранённый attempt требует предусмотренного rollback.
`up -d --no-deps --no-build --pull never` применяется только к `immich-server`.
Все остальные container IDs, volumes, mounts, networks и настройки сравниваются.

Успех: `RESULT exit=0` и `PASS exact running image/source, healthy APIs,
API+microservices and preserved paused jobs`. Это подтверждает deployment checks,
но не physical S23/iPhone и не удаление production media.

## Чистая установка Ubuntu 24.04

Этот маршрут предназначен только для нового сервера с уже установленными Docker,
Compose, Python 3.11+ и tmux. При наличии проекта `immich`, зарезервированных
контейнеров или занятого порта 2283 installer требует маршрут upgrade. Никакого
reset PostgreSQL, удаления volumes или пересоздания существующей Gallery нет.

Пакет использует официальный ML 5.7.1 с подтверждёнными amd64 identities:
registry `ghcr.io/open-noodle/gallery-ml@sha256:711baa1712989ed52b8f3d02955d97641eceb614386cc4d096c7934538cb4f72`,
config `sha256:adb5169bfdaa615c8ebd0e38530e10f17cc64202aeb5adf63335e95bad55f31b`.
Скрипт принимает только этот опубликованный immutable ML input из пакета,
проверяет platform и точное происхождение manifest/config ID. PostgreSQL и
Valkey также закреплены digest из официального Compose. Mutable `latest` не нужен.

Для NAS сначала предоставьте действующие exports на **новом** сервере. Installer
не меняет NFS permissions, не делает remount и не открывает общий RW-доступ.
Для примера ниже оператор заранее создаёт `/mnt/gallery-external/docice` и
подключает разрешённый export только RO. IP и export следует брать из DSM NFS
Permissions, а не выдумывать; у HP они уже известны из сохранённого аудита:

```bash
# Только новый сервер, только после разрешения его администратора.
sudo mkdir -p /mnt/gallery-external/docice
sudo mount -t nfs -o ro,nosuid,nodev 10.10.10.95:/volume1/homes/docice/Photos /mnt/gallery-external/docice
```

Это отдельная явная настройка нового сервера, а не команда для production HP.
Для chudo_anna и Lenia используйте их проверенные exports и отдельные mount
targets. Постоянные mounts на новом сервере настраивает его администратор;
installer проверяет фактические NFS source/target/options и не изменяет fstab.

Создайте приватный JSON-конфиг. `readOnly:true` — обычный защищённый режим.
Для managed NAS допускается отдельная запись с `destination:"/data"`,
`readOnly:false` и уже разрешённым RW export, причём managed каталог при чистой
установке должен быть пустым. Existing managed media требует upgrade, а не clean
install. Writable external требует одновременно имеющегося RW mount и явного
режима конкретной библиотеки у владельца в Gallery; нельзя сменить только JSON
и считать NAS разрешённым.

Одна команда установки после скачивания и проверки пакета:

```bash
set -euo pipefail
umask 077
PACKAGE=/mnt/hp-data/gallery-build11-package
: "${BUILD11_SHA256SUMS_SHA256:?Нужен опубликованный checksum}"
printf '%s  %s\n' "$BUILD11_SHA256SUMS_SHA256" "$PACKAGE/SHA256SUMS" | sha256sum -c --strict -
(cd "$PACKAGE" && sha256sum -c --strict SHA256SUMS)
NEW_ROOT=$(mktemp -d "$HOME/gallery-build11-install-XXXXXXXX")
CONFIG_ROOT=$(mktemp -d "$HOME/gallery-build11-config-XXXXXXXX")
python3 - "$CONFIG_ROOT" "$PACKAGE" <<'PY'
import json, os, secrets, sys
from pathlib import Path
config, package = map(Path, sys.argv[1:])
with os.fdopen(os.open(config/'private.env', os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600), 'w') as file:
    file.write('DB_PASSWORD='+secrets.token_hex(32)+'\nDB_USERNAME=postgres\nDB_DATABASE_NAME=immich\nTZ=Europe/Moscow\n')
with os.fdopen(os.open(config/'nas.json', os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600), 'w') as file:
    json.dump({'schemaVersion':1,'mounts':[{'source':'/mnt/gallery-external/docice','destination':'/external/docice',
        'nfsSource':'10.10.10.95:/volume1/homes/docice/Photos','readOnly':True}]},file)
value=json.loads((package/'release-operator.json').read_text())['machineLearningImage']
(config/'ml-image-id.txt').write_text(value+'\n')
print('PASS private new-server configuration created; credentials not printed')
PY
ML_IMAGE=$(cat "$CONFIG_ROOT/ml-image-id.txt")
printf 'INSTALL_ROOT=%s CONFIG_ROOT=%s\n' "$NEW_ROOT" "$CONFIG_ROOT"
sudo -v
tmux new-session -s gallery-build11-install bash -c '
  set -uo pipefail; umask 077
  journal=$(mktemp "$3/install-XXXXXXXX.log")
  GALLERY_FRESH_INSTALL_APPROVED=YES \
    bash "$1/tools/gallery-install.sh" "$1" "$2" "$3/private.env" "$4" \
    --execute-approved --nas-storage-config "$3/nas.json" 2>&1 | tee "$journal"
  result=$?
  printf "RESULT exit=%s journal=%s\n" "$result" "$journal"
  exec bash
' _ "$PACKAGE" "$NEW_ROOT" "$CONFIG_ROOT" "$ML_IMAGE"
```

Без NAS используйте ту же команду installer без `--nas-storage-config`; managed
storage будет новым локальным каталогом внутри `NEW_ROOT`. Нельзя добавлять
arbitrary environment keys или worker exclusions в env-файл. Password содержит
20–128 безопасных ASCII символов; приведённый генератор формирует новый секрет,
не выводя его. Существующие accounts/keys не заменяются в upgrade-маршруте.

После `PASS fresh Build11 server healthy` откройте `http://SERVER:2283`, создайте
первого администратора штатной формой Gallery и добавьте external library с
container path `/external/docice`. Внешний HTTPS подключается существующим
reverse proxy нового сервера к localhost:2283; installer не меняет nginx/DNS.
Для HP используйте текущий адрес Gallery и прежние accounts. Приложение API на
новом сервере не следует публиковать в интернет без HTTPS и сетевой политики.

Прерванный startup возобновляется **той же** installer-командой с теми же
PACKAGE/NEW_ROOT/CONFIG_ROOT/ML_IMAGE. Source, package checksum, env, Compose,
image IDs и NFS identity должны совпадать. Завершённая установка проверяется без
повторного `up`; новая конфигурация не накладывается поверх старой молча.
Результаты clean-install синтетических тестов и реального Ubuntu/NFS запуска
указываются отдельно в release report.

## Android: существующая HP подпись, без пересборки

Подписывайте только после отдельного разрешения владельца ключа, от существующего
пользователя signing pipeline. Нужны JDK 17, Android SDK Build Tools 36 и прежние
ignored `key.jks`/`key.properties` с правами 0600. Не копируйте ключ в GitHub.
Output — **каталог**, в нём создаётся `Foto.apk`:

```bash
set -euo pipefail
umask 077
PACKAGE=/mnt/hp-data/gallery-build11-package
SIGNED_PARENT=$(mktemp -d "$HOME/gallery-build11-signed-XXXXXXXX")
PROFILE_SHA=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["profileSHA256"])' "$PACKAGE/release-operator.json")
python3 -B "$PACKAGE/tools/android_sign_package.py" \
  --profile "$PACKAGE/candidate-profile.json" --profile-sha256 "$PROFILE_SHA" \
  --input-apk "$PACKAGE/android/app-release.apk" \
  --android-directory /opt/gallery-fork/mobile/android \
  --output "$SIGNED_PARENT/output" --authorize-production-signing
```

Signing wrapper проверяет неизменность payload CI APK, package
`de.opennoodle.gallery`, 5.7.3/build11, native libraries, zip alignment и сертификат
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
Вывод содержит точный APK path/SHA-256. CI debug APK не является обновлением
production-signed приложения. Установите `Foto.apk` поверх приложения, без
uninstall/очистки данных. Перед установкой на S23 сохраните доступ к прежнему
APK; Android rollback с меньшим versionCode ограничен ОС и не гарантирует
сохранение локальной БД. Backend rollback и downgrade mobile — разные операции.

## iPhone: прежний SideStore/LocalDevVPN

Скачайте `ios/Photos-unsigned.ipa` с опубликованным checksum. Unsigned IPA нельзя
установить напрямую. Сохраните прежний Apple ID/Personal Team, bundle mappings,
App Groups, Runner, ShareExtension и WidgetExtension; платная подпись не нужна.

Если существующая установка использует prepared seed, на macOS с `codesign`
запустите прежний deterministic preparation с **тем же** team ID:

```bash
: "${SIDESTORE_EXISTING_TEAM_ID:?Укажите прежний Personal Team ID}"
IPA_SHA=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["ios"]["sha256"])' "$PACKAGE/candidate-profile.json")
python3 "$PACKAGE/ios-tools/release/prepare_sidestore.py" \
  --ipa "$PACKAGE/ios/Photos-unsigned.ipa" --input-sha256 "$IPA_SHA" \
  --team-id "$SIDESTORE_EXISTING_TEAM_ID" --version 5.7.3 --build 11 \
  --output "$HOME/Photos-Build11-SideStore-seed-unsigned.ipa"
```

Это ad-hoc seed, ему всё равно требуется Personal Team signing в SideStore.
При запросе выберите **Keep App Extensions (Register App ID for Each Extension)**.
Удалять extensions для скрытия signing failure нельзя. Используйте прежний
LocalDevVPN/pairing/refresh маршрут и обновляйте существующую app identity.
Проверьте ShareExtension, WidgetExtension и App Group на физическом iPhone;
7-дневное обновление подписи остаётся обязанностью владельца SideStore.

## Откат только после отдельного разрешения

Пакет включает проверенный fallback image и реальный image-level HTTP rollback
report. Нельзя подставить старый image с неизвестным source. Forward-only
additive migration и tombstones сохраняются: не удаляйте столбцы и записи.
Old runtime отказывает новым storage grants и должен работать с Trash/Restore.

```bash
sudo -v
GALLERY_DEPLOYMENT_APPROVED=YES bash "$PACKAGE/tools/gallery-rollback.sh" \
  "$PACKAGE" "$STATE" "$OLD_RUN" "$BUILD11_NAS_EVIDENCE" --execute-approved
bash "$PACKAGE/tools/gallery-verify.sh" "$PACKAGE" "$STATE" "$OLD_RUN" "$BUILD11_NAS_EVIDENCE"
```

Rollback меняет только server image. Сохранённый backup не восстанавливается
поверх новых live records автоматически. Уже окончательно удалённые файлы
image rollback не возвращает: их отдельно восстанавливает владелец из настоящих
NAS snapshots/backup. Если health check не прошёл, сохраните state и private log,
используйте этот rollback; не выполняйте `compose down`, orphan removal или SQL
repair. Clean install не имеет предыдущего production image: при ошибке его
данные сохраняются, installer не очищает новые volume/каталоги.

## Приёмка и состояние очереди

Только disposable-фото и короткие видео с известными SHA-256: один/несколько,
phone-only/NAS-only/both, Gallery-only/device-only/everywhere, OS denial,
offline/restart, Live/Motion, chronological restore/альбомы, selective/Empty Trash,
RO external отказ, явно writable external удаление, cross-owner/shared originals
защита. Полная [русская инструкция пользователя](BUILD11-USER-MANUAL-RU.md)
содержит проверку интерфейса. Проверьте новую upload: thumbnail и preview должны
появиться, photo/video viewer — открыться. API и microservices должны работать.
Backup, search, faces, sharing, Memories/ML проверяются без full-library анализа.

По свежему audit production `backgroundTask` был `paused=false`; это не считается
разрешением. После отдельного approval pause/drain gate очередь должна оставаться
paused ради сохранённых jobs. Inline permanent deletion работает отдельно;
автоматический срок корзины, queued retries и derivative cleanup на HP
**BLOCKED**, пока владелец отдельно не одобрит review/activation очереди. Clean
install с активной upstream queue проверяется отдельно; установщик не имитирует
production expiration PASS.

## Точные STOP и действия

| Код                                                                                        | Что делать                                                                                                                                     |
| ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `RELEASE_PACKAGE_FILE_CHANGED` / `PINNED_*`                                                | Не запускать. Снова скачать официальный пакет по immutable URL и сравнить опубликованный checksum; исходный state сохранить.                   |
| `COMPLETE_BUILD10_BRIDGE_FIRST`                                                            | Использовать отдельно одобренный exact-six bridge через общий `upgrade --complete-confirmed-cleanup`; не выдумывать completion receipt.        |
| `SIX_CONFIRMED_CLEANUP_COMPLETION_RECEIPT_REQUIRED_NO_REPLAY`                              | Завершение не доказано. Передать сохранённый private report владельцу; не удалять jobs и не повторять files вручную.                           |
| `NAS_RECOVERY_VERIFICATION_EXPIRED_NO_TIMESTAMP_REFRESH`                                   | Выполнить настоящий snapshot export/content verification существующим NAS recovery инструментом. Не менять timestamp.                          |
| `INTERRUPTED_INSTALL_CONTEXT_CHANGED` / `*_CONFIGURATION_CHANGED`                          | Вернуть тот же подписанный пакет и неизменный private config; существующий state не редактировать. Другую конфигурацию installer не применяет. |
| `EXACT_NAS_NFS_SOURCE_AND_TARGET_REQUIRED`                                                 | Сверить настройки нового сервера с действительным DSM export; production mounts не менять и не обходить проверку.                              |
| `NFS_WRITE_MODE_MUST_ALREADY_BE_EXPLICITLY_CONFIGURED`                                     | Read-only mount не поддерживает writable режим. Оставить библиотеку read-only либо отдельно получить narrow NAS export authorization.          |
| `API_AND_MICROSERVICES_REQUIRED`                                                           | Текущая конфигурация API-only небезопасна. Сначала отдельное согласованное исправление effective Compose; release guard не отключать.          |
| `EXISTING_APPLY_ATTEMPT_*` / health failure                                                | Не повторять apply автоматически. Использовать проверенный rollback выше с тем же state.                                                       |
| `PINNED_MACHINE_LEARNING_DEPENDENCY_REQUIRED`                                              | Нужен настоящий immutable upstream ML reference в пакете; mutable latest или произвольный локальный image не допускаются.                      |
| `REVIEWED_COMPATIBILITY_CONTRACT_REQUIRED` / `REAL_ISOLATED_ROLLBACK_TEST_REPORT_REQUIRED` | Receipt отсутствует или rollback HTTP/Trash/Restore не доказан. Не использовать `sha256:893281ae…`; получить новый receipt в disposable CI.    |
| `DELETION_QUEUE_NOT_PAUSED` / `DELETION_QUEUE_NOT_EMPTY`                                   | Оставить queue как есть, выполнить только поддерживаемый pause и естественный drain; не clean/kill/retry/clear.                                |
| `FRESH_BACKUP_AND_EXACT_RESTORE_REQUIRED`                                                  | Создать новый backup и проверить restore именно его байтов в изолированном PostgreSQL; старые 14 файлов недостаточны.                          |

Private logs могут содержать topology/recovery metadata, поэтому не публикуйте
их целиком. Публичный report содержит только PASS/STOP, source/image hashes,
count/status и путь operator journal; credentials, API keys и private media names
в него не включаются. Перед отправкой private журнала обезличьте его.

## Изготовление бинарного пакета — CI/maintainer, не конечный пользователь

После завершённых same-source jobs скачайте backend/APK/IPA один раз. Mobile
build-only input `version` пустой; iOS выполняется перед Android из-за общего
concurrency group. Используются существующие workflows, Flutter 3.47.2/Xcode 26.2
и CocoaPods locks, без paid release lane.

```bash
python3 scripts/release/build11_artifacts.py "$ARTIFACTS" "$RELEASE_SHA" \
  "$BACKEND_RUN" "$ANDROID_RUN" "$IOS_RUN" "$ARTIFACTS/candidate-profile.json"
python3 scripts/release/build11_package.py \
  --artifacts "$ARTIFACTS" --rollback-artifacts "$ROLLBACK_ARTIFACTS" \
  --profile "$ARTIFACTS/candidate-profile.json" --profile-sha256 "$PROFILE_SHA" \
  --compatibility "$REVIEWED_COMPATIBILITY" --compatibility-sha256 "$COMPATIBILITY_SHA" \
  --output "$NEW_PACKAGE_OUTPUT" \
  --machine-learning-image sha256:adb5169bfdaa615c8ebd0e38530e10f17cc64202aeb5adf63335e95bad55f31b \
  --machine-learning-reference ghcr.io/open-noodle/gallery-ml@sha256:711baa1712989ed52b8f3d02955d97641eceb614386cc4d096c7934538cb4f72
```

Assembler принимает только действительный `build11-rollback-runtime.json` из
backend CI с точными source/image/archives и PASS фактического old-runtime HTTP
на upgraded schema. Только startup migrations и unit tests не заменяют этот
report. Каждый исполняемый файл, artifact и документ входит в `SHA256SUMS`.
Фактические Ubuntu clean-install/upgrade/NFS/device результаты публикуются
отдельно; непроверенный сценарий не превращается в PASS по наличию скрипта.
