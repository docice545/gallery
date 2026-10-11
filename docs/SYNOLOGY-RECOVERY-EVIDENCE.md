# Synology recovery evidence — Gallery 5.7.3 (10)

Этот документ описывает подготовку доказательств восстановления. Команды не
разрешают удаление, не выполняют deploy и не меняют NAS. Установка bind mounts,
подготовка policy и согласие владельца имеют отдельные операторские разрешения.
Ни одна production-команда из этого документа не выполнялась при разработке.

## Что исправлено

Раньше NAS-диагностика сохраняла `provenance` только для shares `homes`/`Immich`,
без времени каждого экспорта и без привязки к корням конкретного owner/scope.
Генератор корректно требовал `snapshot_provenance` для каждого корня, но штатного
перехода между этими форматами не было.

Теперь используются существующие компоненты:

1. `trash_recovery_inputs.py capture` вызывает существующий read-only
   `collectRootIdentities` в **работающем** `immich_server`. По реальным Docker bind
   mounts определяет host paths, сравнивает device/inode, повторяет проверку
   контейнера, mounts и identities. Записывает приватные `roots.json` и
   `capture.json`. Конфигурация окружения контейнера и секреты не читаются.
2. NAS-диагностика экспортирует настоящие файлы из подтверждённого snapshot для
   каждого запрошенного корня. Сохраняет фактические `exportedAt`, ID операции,
   source paths, hashes, размеры и root/owner/scope bindings в `rootExports`.
3. `trash_recovery_inputs.py prepare` проверяет успешный отчёт, snapshot metadata,
   исходные времена, namespace, owner/scope и содержимое файлов. Создаёт
   совместимые per-root `snapshot-provenance-N.json`, `nas-proof.json`,
   `roots.json` и завершающий `input-receipt.json`. Повторно использует проверки
   существующего генератора; ничего не подписывает и не выдаёт согласие.
4. `trash_recovery_evidence.py` проверяет настоящий PostgreSQL restore receipt и
   точные bytes backup, все inputs и completion receipt, затем подписывает
   существующий build-10 envelope. Другой owner/scope или изменённый manifest
   блокирует выпуск до чтения ключа. Формат server envelope/API/БД не изменён.

Старый `nas-proof.json` без export receipts **не превращается** в свежий proof.
Ошибка `NAS_EXPORT_RECEIPT_REQUIRED_RUN_DIAGNOSTIC` требует нового фактического
экспорта. `mtime`, дата запуска преобразователя или старый `nas-verified.json`
не заменяют время восстановления. Предыдущие отчёты и PostgreSQL PASS остаются
нетронутыми.

## Обязательные входы и ограничения

- Проверенная копия этого Git commit на HP; Python 3.11+, Node.js с Ed25519,
  Bash, curl, findmnt и доступ к **локальному** Docker Unix socket.
- Работающий Gallery build 10 с compiled collector и окончательной mount
  configuration. Любое пересоздание контейнера/remount после capture означает
  STOP и новую подготовку.
- Реальные UUID трёх libraries и их владельцев из существующего admin API.
  Не использовать email, имя папки или одинаковый `ownerId` для всех.
- Реальные DSM snapshot IDs для **всей** `homes` и `Immich`; последний должен быть
  locked. ID/даты проверяются через DSM Snapshot Replication; NFS-доступ сам по
  себе не доказывает происхождение. Диагностика проверяет NFS snapshot directory
  либо DSM HTTPS metadata + File Station download, затем требует явного
  подтверждения оператором scope snapshots. DSM credentials находятся только в RAM.
- Photo **и** video из каждого разрешаемого корня должны реально существовать в
  snapshot, экспортироваться в отдельное HP staging и совпадать с live originals
  по SHA-256 и размеру. Отсутствующий тип означает STOP. Нельзя объявить его
  существующим или заменить snapshot обычной копией live-файла.
- Настоящий `backup-verified.json` существующей isolated-restore процедуры и
  **тот самый** SQL/gzip backup; `checkedAt` не старше 24 часов. NAS-диагностика
  не повторяет PostgreSQL restore и не обновляет его receipt. Если receipt устарел,
  нужен отдельно разрешённый новый isolated restore, не редактирование JSON.
- Отдельный recovery Ed25519 private PKCS#8 PEM `0600` под операторским UID в
  каталоге `0700`; не Android/iOS/auth key. Public key — SPKI PEM. Private key
  никогда не передаётся в контейнер. Уже установленный public key не заменять
  без отдельной процедуры смены доверия.

Новый NAS adapter поддерживает реальные NFS/NFS4 coordinates Synology
`10.10.10.95:/volume1/homes` и `/volume1/Immich`, включая подкорни/bind aliases.
Неподтверждённый сервер или другой filesystem отклоняется. Для управляемого
хранилища на локальном HP filesystem нужен его настоящий tested photo/video
backup/export по [существующему формату](../specs/testing/2026-10-10-trash-recovery-evidence.md).
Нельзя выдавать NAS provenance для локального HP root. Для managed originals
на Synology можно использовать этот же flow с `scope: managed` и разрешёнными
owner upload/library roots; права external libraries от этого не появляются.

Private state всегда создаётся заново (`mktemp -d`, `0700`); outputs — `0600`,
без overwrite. Экспорт ограничен 256 MiB на sample, 2 GiB суммарно; scans имеют
лимиты количества/depth/time. Неполный отчёт или частично подготовленные inputs
не имеют completion receipt и не могут быть штатно подписаны. Сохраняйте их
для разбора, не удаляйте старые recovery evidence.

## 1. Сначала установить trust store — только после отдельного разрешения

В существующий Compose service `immich-server` добавить **один read-only bind**
операторского trust directory, содержащего `public.pem` и `evidence/`:

```yaml
services:
  immich-server:
    volumes:
      - /mnt/hp-data/gallery-deletion-recovery:/run/gallery-deletion-recovery:ro
```

Host directory/evidence directory: `0555`; public key/envelopes: single-link
regular `0444` files. Проверить effective Compose, сохранение **всех** существующих
volumes, networks и environment, работу API **и microservices**. Установка этой
конфигурации требует отдельного deploy approval; не запускать Compose сейчас.
Не добавлять `IMMICH_WORKERS_INCLUDE=api`/`IMMICH_WORKERS_EXCLUDE=microservices`,
не использовать `down -v`/`--remove-orphans`. ML/inpainting/VPN и остальные
services не трогать. Root-приложению chmod-only protection недостаточно: bind
действительно должен быть `ro` в mount namespace контейнера.

Default paths уже поддерживаются:
`GALLERY_DELETION_RECOVERY_DIR=/run/gallery-deletion-recovery/evidence` и
`GALLERY_DELETION_RECOVERY_PUBLIC_KEY=/run/gallery-deletion-recovery/public.pem`.
Не монтировать private PEM или каталог с ним.

Для первоначальной установки, после отдельного approval, получить SPKI из
существующего recovery key и создать новый пустой trust store. Если store/key
уже есть, не выполнять инициализацию повторно: сверить существующий SPKI с
доверенным recovery key. Это не создаёт Android/Apple/account ключей.

```bash
set -euo pipefail
umask 077
RECOVERY_KEY='<existing operator private PKCS#8 PEM>'
set -o noclobber
PUBLIC_PEM='<unused private operator path>/public.pem'
TRUST_SOURCE=/mnt/hp-data/gallery-deletion-recovery
test ! -e "$PUBLIC_PEM"
openssl pkey -in "$RECOVERY_KEY" -pubout > "$PUBLIC_PEM"
sudo test ! -e "$TRUST_SOURCE"
sudo mkdir -m 555 "$TRUST_SOURCE"
sudo mkdir -m 555 "$TRUST_SOURCE/evidence"
sudo install -m 444 "$PUBLIC_PEM" "$TRUST_SOURCE/public.pem"
```

После отдельного разрешения применить только reviewed server volume binding
сверху и проверить действительную `ro` защиту. Только **после** final container
creation перейти к capture ниже. Image-only release helper не устанавливает
дополнительные mounts скрытым образом.

## 2. Приватные library inputs и root capture — чтение

Запускать как `doctoriceadm` после разрешённой установки build 10 и trust mounts.
`SOURCE` — отдельный проверенный checkout указанного в handoff commit; production
checkout не менять. Задать три реальные library UUID и путь **существующего**
admin API key. API key не передаётся в argv/environment и не печатается.

```bash
set -euo pipefail
umask 077
SOURCE=/mnt/hp-data/codex-work/gallery-web-release
export PATH=/mnt/hp-data/codex-toolchain/node/bin:$PATH
EXPECTED_COMMIT='<full SHA from this handoff>'
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$EXPECTED_COMMIT"
test -z "$(git -C "$SOURCE" status --porcelain)"
ADMIN_KEY_FILE=/home/doctoriceadm/.config/gallery-release/admin-api-key
API=http://127.0.0.1:2283/api
LIBRARIES=('<docice library UUID>' '<chudo_anna library UUID>' '<Lenia library UUID>')
PHASE=$(mktemp -d /home/doctoriceadm/gallery-evidence-inputs-XXXXXXXX)
python3 - "$ADMIN_KEY_FILE" "$PHASE/api-header" <<'PY'
import os, stat, sys
from pathlib import Path
path = Path(sys.argv[1])
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
with os.fdopen(fd, 'r') as source:
    metadata = os.fstat(source.fileno())
    assert stat.S_ISREG(metadata.st_mode) and stat.S_IMODE(metadata.st_mode) == 0o600
    key = source.read(16385).strip()
    assert 0 < len(key) <= 16384 and '\n' not in key and '\r' not in key
with os.fdopen(os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as out:
    out.write('x-api-key: ' + key + '\n')
PY
for index in 0 1 2; do
  [[ "${LIBRARIES[$index]}" =~ ^[a-f0-9-]{36}$ ]]
  mkdir -m 700 "$PHASE/capture-$index"
  curl --fail --silent --show-error --header "@$PHASE/api-header" \
    "$API/libraries/${LIBRARIES[$index]}" --output "$PHASE/library-$index.json"
  python3 "$SOURCE/scripts/release/trash_recovery_inputs.py" capture \
    --library "$PHASE/library-$index.json" --output-dir "$PHASE/capture-$index"
done
python3 - "$PHASE" <<'PY'
import json, os, sys
from pathlib import Path
base = Path(sys.argv[1])
values = [json.loads((base / f'capture-{i}/capture.json').read_text()) for i in range(3)]
assert len({v['ownerId'] for v in values}) == 3 and len({v['scope'] for v in values}) == 3
with os.fdopen(os.open(base / 'captures.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as out:
    json.dump({'version': 1, 'captures': [str(base / f'capture-{i}') for i in range(3)]}, out)
PY
printf 'PASS private capture; state=%s\n' "$PHASE"
```

Для `managed` использовать `capture --request <private-request.json>`:
`{"version":1,"ownerId":"<real UUID>","scope":"managed","roots":["<existing owner root>"]}`.
Корни получать из реальной storage configuration, не выбирать общий `/data` или
чужой owner directory. В capture index добавить только NFS roots; сервер вновь
проверит owner/importPaths и exclusive boundaries при preparation.

## 3. Фактический snapshot export — отдельная read-only recovery операция

После разрешения оператором чтения snapshots и локального staging:

```bash
export GALLERY_NAS_RECOVERY_CAPTURES="$PHASE/captures.json"
export GALLERY_NAS_HOMES_SNAPSHOT='<actual homes snapshot ID from DSM>'
export GALLERY_NAS_IMMICH_SNAPSHOT='<actual locked Immich snapshot ID from DSM>'
bash -n "$SOURCE/scripts/diagnostics/gallery-nas-recovery-565ef38.sh"
bash "$SOURCE/scripts/diagnostics/gallery-nas-recovery-565ef38.sh"
```

Переменные выбирают только **существующий** snapshot; скрипт не создаёт снимок
и не принимает выдуманный ID без проверки источника. Без overrides сохраняется
исторический выбор подтверждённых снимков 09.10.2026. Скрипт запросит прежний PG
PASS и полный PASS audit, а при отсутствии NFS snapshot access — DSM HTTPS URL,
доверенный CA и существующий read account. Не отключать TLS verification. Не
предполагается, что `#snapshot` доступен по NFS.

Использовать **новый** напечатанный каталог `gallery-nas-recovery-*` только при
`NAS_RECOVERY: PASS`, `PREVIOUS_EVIDENCE: PASS_UNCHANGED`, пустом `blockers` и
PASS каждого requested root. `ABSENT`/`NO_VERIFIED_SAMPLE` — STOP, не фиктивный
photo/video. Нельзя создавать canaries на production без отдельного разрешения.

## 4. Подготовить совместимые входы и подписать — локальные файлы

Задать реальные абсолютные пути нового NAS state, свежего tested PostgreSQL
backup/receipt и существующего private recovery key; их содержимое не печатать.

```bash
NAS_STATE='<new PASS gallery-nas-recovery directory>'
BACKUP='<exact tested SQL/gzip backup absolute path>'
PG_RECEIPT='<fresh restore state>/backup-verified.json'
RECOVERY_KEY='<operator private directory>/recovery-signing.pem'
for index in 0 1 2; do
  mkdir -m 700 "$PHASE/prepared-$index" "$PHASE/signed-$index"
  python3 "$SOURCE/scripts/release/trash_recovery_inputs.py" prepare \
    --capture-dir "$PHASE/capture-$index" --nas-state "$NAS_STATE" \
    --output-dir "$PHASE/prepared-$index"
  OWNER=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["ownerId"])' "$PHASE/capture-$index/capture.json")
  SCOPE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["scope"])' "$PHASE/capture-$index/capture.json")
  python3 "$SOURCE/scripts/release/trash_recovery_evidence.py" \
    --owner-id "$OWNER" --scope "$SCOPE" --roots "$PHASE/prepared-$index/roots.json" \
    --backup "$BACKUP" --postgres-receipt "$PG_RECEIPT" \
    --nas-proof "$PHASE/prepared-$index/nas-proof.json" --signing-key "$RECOVERY_KEY" \
    --output-dir "$PHASE/signed-$index" --valid-for-hours 24 > "$PHASE/proof-$index.json"
done
```

`evidenceSHA256` из `proof-N.json` — это `recoveryProof`, а не backup SHA.
Подпись не обновляет `checkedAt`/`exportedAt`. Expiry — минимум issuance+24h,
restore+24h и самого раннего sample export+24h. Выпуск через час не продлевает
старый export ещё на 24h. При истечении повторить реальный recovery/export и
preparation; новое preparation сбрасывает consent. Server проверяет подпись,
scope, expiry и current filesystem identity перед каждым защищённым unlink.

## 5. Установить envelope и подготовить policy — отдельное разрешение

После отдельного operator approval скопировать каждый digest-named файл в уже
смонтированный host trust store штатной командой ниже. Она сравнивает installed
SPKI с операторским public key, проверяет Ed25519 и SHA-256 **всех** входящих
envelopes до копирования. Новое имя создаёт через `O_CREAT|O_EXCL`, проверяет
bytes, `nlink==1` и `0444`. Существующие имена не переписываются; несовпадение
даёт STOP. Copy failure сохраняет файлы для разбора и не выдаёт consent.
Private key и исходные
media/provenance receipts остаются на HP вне контейнера. Динамическое добавление
нового envelope в существующий directory bind не требует recreate; иначе
пересобрать capture/evidence после нового mount namespace.

```bash
for index in 0 1 2; do
  DIGEST=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["evidenceSHA256"])' "$PHASE/proof-$index.json")
  [[ "$DIGEST" =~ ^[a-f0-9]{64}$ ]]
  sudo env PATH="$PATH" python3 "$SOURCE/scripts/release/trash_recovery_inputs.py" publish \
    --public-key "$PUBLIC_PEM" --envelope "$PHASE/signed-$index/$DIGEST.json" \
    --store "$TRUST_SOURCE"
done
```

`publish` не меняет mounts, public key, policies, workers или consent. Если store
не `0555`, ключ не совпадает, подписи нет или имя/digest/bytes не совпадают,
операция отказывается. Server отдельно требует действительный `ro` bind и
проверяет current evidence перед разрешением unlink.

Для каждого другого owner администратор вызывает существующий
`PUT /api/assets/deletion-policy`. Сформировать private JSON из
`prepared-N/input-receipt.json`, `prepared-N/roots.json` и `proof-N.json`:

```json
{
  "ownerId": "<exact capture owner UUID>",
  "scope": "<exact library UUID>",
  "enabled": false,
  "roots": ["<exact verified import root>"],
  "recoveryProof": "<evidenceSHA256>",
  "verifiedExclusiveRoots": true
}
```

Перед checkbox/полем `verifiedExclusiveRoots` оператор проверяет DSM ACL,
NFS UID/GID mapping и отсутствие других writers/общих originals. Это не
утверждение, которое следует выставлять автоматически. Отправлять после approval:

```bash
curl --fail --silent --show-error --request PUT --header "@$PHASE/api-header" \
  --header 'Content-Type: application/json' --data-binary '@<private policy JSON>' \
  "$API/assets/deletion-policy" --output '<unused private response file>'
```

Backend отклоняет `enabled:true` от administrator preparation. Для своей library
администратор также может подготовить installed proof через Android/web Trash.
Проверка proof не даёт администратору права согласиться за другой owner.

## 6. Согласие владельца через Android/web и приёмка

Каждый владелец отдельно входит в **свой существующий** аккаунт. Android:
Корзина → ⋮ → **Разрешение удаления из внешней библиотеки** → точная библиотека →
**Разрешить удаление из этой библиотеки** → явное подтверждение. На web открыть
аналогичный раздел Корзины. Поле proof для non-admin не требуется после admin
preparation. Managed имеет отдельное **Разрешение окончательного удаления**.
Owner consent другого owner/library, managed→external и expired proof запрещены.
**Отозвать разрешение** работает без доступного NFS или действующего proof.

Это инструкция, не автоматическое включение. Реальное разрешение/приёмку сначала
проверить на отдельно одобренном disposable owner/library, не семейных originals:
нет consent → файл остаётся; soft Trash → Restore сохраняет hash/chronology;
consent → точные выбранные originals удаляются с подтверждёнными receipts;
mixed scopes без разрешения → нет нового unlink; revocation/restart/network loss →
безопасный retry; другой owner/control и 291 offline index tombstones не меняются.
Empty Trash проверять только когда весь тестовый Trash disposable. Проверить
API/microservices, новые thumbnail+preview, S23/iPhone OS-denial и sync/rescan.

Результаты Linux mocks не подтверждают реальные DSM ACL/NFS semantics или
physical devices. Read-only mounts остаются read-only и не могут удалять файлы.
Никакого обхода permissions, automatic retention или legacy FileDelete activation
нет. Неизвестный карантин, root remount или смена namespace остаётся STOP.

## Доверие и rollback

Ed25519 удостоверяет **доверенного оператора**, а не отдельную подпись DSM.
NAS source проверен диагностикой + явным snapshot scope attestation; signer может
сфальсифицировать private receipts, если сам оператор злонамерен. Сравнение hashes
без snapshot source/metadata не доказывает происхождение; данная цепочка требует
оба. Sample recovery не доказывает восстановимость каждого файла.

Не включать production deletion до separately approved реального snapshot/NFS
acceptance, protected store проверки и согласия каждого owner. Отозвать consent
можно независимо от evidence. Не удалять tombstones/receipts/quarantine, не
откатывать к legacy unguarded unlink. Image rollback не возвращает unlinked bytes;
per-file recovery из проверенного snapshot требует отдельного разрешения.
Новых migrations/API/пользовательских credentials в этом изменении нет.

## Автоматизированные результаты этой интеграции — 11.10.2026

| Проверка                                                                                    | Результат                                                                              |
| ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Generator + capture/prepare/publish fixtures                                                | 56 PASS, 0 FAIL/SKIP в disposable cloud container под UID 0                            |
| Существующие NAS automount/mapping fixtures                                                 | 16 PASS, 0 FAIL/SKIP                                                                   |
| Backend authorization/Trash/library/filesystem/controller unit suites                       | 455 PASS, 0 FAIL/SKIP; включает 57 signed-evidence и 98 filesystem тестов              |
| PostgreSQL deletion/retention/Timeline suites                                               | 92 PASS, 0 FAIL/SKIP: 83 deletion/retention + 9 Timeline, isolated disposable DB/files |
| Существующие predeploy guards/image identity checks                                         | 37 PASS; 4 opt-in disposable predeploy fixtures SKIP в этом запуске                    |
| Full backend TypeScript; scoped ESLint/Prettier; Bash/Python syntax; Bash blocks инструкции | PASS                                                                                   |

Один host test публикации был SKIP под UID 1000 и затем выполнен успешно под
UID 0 в disposable container. Начальный Docker запуск с `/tmp` 128 MiB правильно
остановился на неизменённом минимуме свободного staging space 1 GiB; после
выделения scratch filesystem 2 GiB все 56 тестов прошли. Ограничения диагностики
не ослаблялись. Container runtime был существующим локальным тестовым image,
network отключён, исходники read-only, данные только временные synthetic fixtures.

Покрыты цепочка настоящих Linux file operations диагностики → per-root inputs →
Ed25519 signing, сохранность прежнего PG receipt, три разных owners, stale/future
времена, изменённые roots/namespace, неверные owner/scope, byte mismatch,
неподтверждённый snapshot, отсутствие подписи, конфликт immutable store и
незавершённая подготовка. NFS/DSM metadata в тестах симулированы; это **не**
production NAS recovery. Flutter/web implementation не изменена; прежние client
suites в этой tooling-интеграции не повторялись. Полный backend lint/full test suite
вместо scoped checks не заявляется. Известные baseline lint failures описаны в
[GALLERY_P1_HANDOFF.md](GALLERY_P1_HANDOFF.md).
