# Gallery 5.7.3 (11): установка, обновление HP и откат

Этот документ относится к собранному пакету Build 11, а не к старому образу
`ea51a8ac`. Точный source commit, URL пакета и SHA-256 публикуются в release handoff
после успешных CI. Пока их нет, выпуск **не готов к установке**. Не подставляйте
примерные хеши, source commit или результаты восстановления.

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
Если предыдущие шесть FileDelete ещё не завершены, сначала выполняется отдельно
подтверждённый существующий Build 10 bridge. Повторного удаления по завершённым
receipts нет. Остальные 21 задания сохраняются paused с точными ID, payload hashes
и порядком. Глобальное возобновление очереди не является частью обновления.

## Необходимые условия

Для HP: оператор `doctoriceadm`, Python 3.11+, Docker с Compose v2, `tmux`,
`curl`, `sha256sum`, существующее право `sudo docker`; пароль вводится только в
обычном `sudo -v`. Скрипты не получают права сами и не устанавливают пакеты.
Публичные зависимости clean install загружаются только по неизменяемым digest.
Для clean install требуется Docker Engine/CLI с API 1.49+ и поддержкой
`docker image inspect --platform` (рекомендуется 28.4.0): platform-specific
inspect проверяет именно `linux/amd64` child manifest закреплённого multi-platform
index. Одного index ID без OS/architecture недостаточно. Проверяются точные
index/manifest/config digests PostgreSQL/Valkey; произвольная замена tag/digest
не допускается. HP upgrade не обновляет Docker и не пересоздаёт эти зависимости.

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

## HP: подготовка до разрешения deployment

Используйте существующий RUN_ROOT
`/home/doctoriceadm/gallery-build10-release-TxDlXAuj`. Он содержит старые sealed
intent, file proofs и hardened rollback; не создавайте вместо него пустую копию.
Не предполагайте, что `ea51a8ac` уже установлен: проверяется фактический container.

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
  sudo -v || { printf "STOP SUDO_AUTHORIZATION_REQUIRED\n"; exec bash; }
  journal=$(mktemp "$2/preparation-XXXXXXXX.log") || { printf "STOP PRIVATE_JOURNAL_REQUIRED\n"; exec bash; }
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
gallery-build11-prepare`. Внутри каждой tmux-сессии выполняется отдельный
`sudo -v`: Ubuntu обычно связывает sudo timestamp с terminal, поэтому авторизации
во внешней SSH-сессии недостаточно для последующих `sudo -n docker`.
Пароль запрашивается до подключения журнала и в него не попадает. Если указанная
tmux-сессия уже существует, сначала подключитесь к ней; повторно создавайте её
только после завершения предыдущего запуска и проверки его `RESULT`.
Сохраните выведенный `PRIVATE_STATE`: это единственный
каталог для check/apply/verify/rollback данного запуска. Нельзя менять receipt
или очищать state ради повторной попытки.

## Статус и обновление доказательств восстановления

`gallery-verify.sh PACKAGE STATE OLD_RUN NAS_EVIDENCE` проверяет неизменность
пакета, сохранённых evidence, image/source/API, конфигурации и paused jobs.
Истечение 24 часов не мешает этой read-only проверке здорового server: вывод
отдельно сообщает, что `apply`/rollback **STOP** до `refresh-recovery`. Успешный
`status` не является подтверждением свежего backup или разрешением deployment.
Изменённые backup bytes, receipts или NAS evidence по-прежнему дают STOP.

Для rollback или отложенного apply старше 24 часов выполните следующий блок.
Он создаёт новый SQL/gzip backup и восстанавливает **именно его** в disposable
PostgreSQL без production volumes/ports/network. Проверяются существующие rows,
ownership, policy fields/modes и migration ledger при migration-only запуске
candidate и hardened fallback на восстановленной копии. Уже установленный
Build 11 не получает повторную миграцию или сброс owner consent.

Нужна настоящая NAS evidence не старше 24 часов. Если она устарела, сначала
оператор выполняет реальную ранее описанную snapshot export/content verification
и указывает новый private каталог; менять `verifiedAt` или подписывать старую
квитанцию заново без проверки запрещено.

```bash
set -euo pipefail
umask 077
test "$(id -un)" = doctoriceadm
: "${PACKAGE:?Укажите тот же проверенный Build11 package}"
: "${STATE:?Укажите существующий private state этого deployment}"
: "${OLD_RUN:?Укажите сохранённый Build10 RUN_ROOT}"
: "${BUILD11_NAS_EVIDENCE:?Нужна настоящая свежая NAS evidence}"
: "${BUILD11_SHA256SUMS_SHA256:?Нужен опубликованный checksum}"
printf '%s  %s\n' "$BUILD11_SHA256SUMS_SHA256" "$PACKAGE/SHA256SUMS" | sha256sum -c --strict -
(cd "$PACKAGE" && sha256sum -c --strict SHA256SUMS)
sudo -v
tmux new-session -s gallery-build11-refresh-recovery bash -c '
  set -uo pipefail; umask 077
  sudo -v || { printf "STOP SUDO_AUTHORIZATION_REQUIRED\n"; exec bash; }
  journal=$(mktemp "$2/recovery-refresh-XXXXXXXX.log") || { printf "STOP PRIVATE_JOURNAL_REQUIRED\n"; exec bash; }
  bash "$1/tools/gallery-upgrade.sh" refresh-recovery "$1" "$2" "$3" "$4" 2>&1 | tee "$journal"
  result=$?
  printf "RESULT exit=%s journal=%s\n" "$result" "$journal"
  exec bash
' _ "$PACKAGE" "$STATE" "$OLD_RUN" "$BUILD11_NAS_EVIDENCE"
```

Успех — `RESULT exit=0` и `PASS fresh recovery generation activated`. Старые
backup/evidence/plan остаются неизменными; новый private child generation
активируется append-only receipt только после завершённых проверок. Отказ или
прерывание до activation оставляет private файлы для разбора, не заменяет старую
квитанцию. Повторный запуск создаёт новый backup, а не подправляет timestamp.
Конкурирующий refresh отклоняется. Отдельное разрешение deployment/rollback всё
равно требуется; refresh не меняет server image, workers, queues или originals.

Старый state без hash-binding metadata можно прочитать в `status`, но он помечен
`HISTORIC_RECOVERY_METADATA_UNPINNED_RUN_REFRESH` и не принимается для изменения
server. Штатный refresh подтверждает новые байты вместо автоматического доверия
старой квитанции. Реальный HP restore/refresh остаётся operator acceptance gate;
unit fixtures не считаются успешным восстановлением production backup.

## HP: одна команда обновления после отдельного разрешения

Перед запуском владелец сервера должен одобрить конкретный Build 11, additive
migration и, если ещё требуется, старый exact-six bridge. Ни документация, ни
наличие файлов не считаются этим разрешением.

Задайте `STATE` из подготовки; если она остановилась до записи плана, после
устранения внешнего prerequisite используйте новый private state, сохранив старый.
В блоке ниже `--complete-confirmed-cleanup` требуется только для незавершённого
Build 10 bridge. Переменная подтверждения cleanup не разрешает удаление других
файлов или запуск остальных 21 jobs.

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
  sudo -v || { printf "STOP SUDO_AUTHORIZATION_REQUIRED\n"; exec bash; }
  journal=$(mktemp "$2/upgrade-XXXXXXXX.log") || { printf "STOP PRIVATE_JOURNAL_REQUIRED\n"; exec bash; }
  GALLERY_DEPLOYMENT_APPROVED=YES GALLERY_ADDITIVE_MIGRATION_APPROVED=YES \
  GALLERY_USER_QUEUED_DELETION_APPROVED=YES \
    bash "$1/tools/gallery-upgrade.sh" upgrade "$1" "$2" "$3" "$4" \
    --execute-approved --approve-migration --complete-confirmed-cleanup 2>&1 | tee "$journal"
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
Valkey закреплены по проверенной цепочке official index → AMD64 manifest →
config. Для чистой установки x86_64 пакет выбирает тот же Valkey9 AMD64 manifest
`sha256:67878c70fc179bb928b1a9b510860aff1c475ff245e91d98d4b2133326bf8e3e`;
upstream source Compose сохраняется, provenance входит в checksummed package.
Image-only HP upgrade сохраняет действующий Redis. Mutable `latest` не нужен.

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
  sudo -v || { printf "STOP SUDO_AUTHORIZATION_REQUIRED\n"; exec bash; }
  journal=$(mktemp "$3/install-XXXXXXXX.log") || { printf "STOP PRIVATE_JOURNAL_REQUIRED\n"; exec bash; }
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
Если backup/NAS evidence старше 24 часов, сначала выполните `refresh-recovery`
выше с тем же state. Rollback не ослабляет freshness или restore-проверки.

```bash
set -euo pipefail
umask 077
: "${PACKAGE:?Укажите тот же проверенный Build11 package}"
: "${STATE:?Укажите private state этого deployment}"
: "${OLD_RUN:?Укажите сохранённый Build10 RUN_ROOT}"
: "${BUILD11_NAS_EVIDENCE:?Укажите проверенную NAS evidence}"
tmux new-session -s gallery-build11-rollback bash -c '
  set -uo pipefail; umask 077
  sudo -v || { printf "STOP SUDO_AUTHORIZATION_REQUIRED\n"; exec bash; }
  journal=$(mktemp "$2/rollback-XXXXXXXX.log") || { printf "STOP PRIVATE_JOURNAL_REQUIRED\n"; exec bash; }
  GALLERY_DEPLOYMENT_APPROVED=YES bash "$1/tools/gallery-rollback.sh" \
    "$1" "$2" "$3" "$4" --execute-approved 2>&1 | tee "$journal"
  result=$?
  if [ "$result" -eq 0 ]; then
    bash "$1/tools/gallery-verify.sh" "$1" "$2" "$3" "$4" 2>&1 | tee -a "$journal"
    result=$?
  fi
  printf "RESULT exit=%s journal=%s\n" "$result" "$journal"
  exec bash
' _ "$PACKAGE" "$STATE" "$OLD_RUN" "$BUILD11_NAS_EVIDENCE"
```

Rollback меняет только server image. Сохранённый backup не восстанавливается
поверх новых live records автоматически. Уже окончательно удалённые файлы
image rollback не возвращает: их отдельно восстанавливает владелец из настоящих
NAS snapshots/backup. Если health check не прошёл, сохраните state и private log,
используйте этот rollback; не выполняйте `compose down`, orphan removal или SQL
repair. Clean install не имеет предыдущего production image: при ошибке его
данные сохраняются, installer не очищает новые volume/каталоги.

Для завершённой **чистой установки** используется отдельный штатный маршрут,
который не требует HP bridge и его legacy очередей. Он проверяет сохранённый
private installation receipt, фактический container/config, неизменность storage
и отсутствие destructive jobs, затем меняет только server image на упакованный
совместимый hardened fallback. PostgreSQL и media не откатываются и не очищаются:

```bash
set -euo pipefail
umask 077
: "${PACKAGE:?Укажите тот же проверенный Build11 package}"
: "${NEW_ROOT:?Укажите сохранённый installation root}"
sudo -v
tmux new-session -s gallery-build11-fresh-rollback bash -c '
  set -uo pipefail; umask 077
  sudo -v || { printf "STOP SUDO_AUTHORIZATION_REQUIRED\n"; exec bash; }
  journal=$(mktemp "$2/fresh-rollback-XXXXXXXX.log") || { printf "STOP PRIVATE_JOURNAL_REQUIRED\n"; exec bash; }
  GALLERY_DEPLOYMENT_APPROVED=YES bash "$1/tools/gallery-rollback.sh" \
    --fresh-install "$1" "$2" --execute-approved 2>&1 | tee "$journal"
  result=$?
  printf "RESULT exit=%s journal=%s\n" "$result" "$journal"
  exec bash
' _ "$PACKAGE" "$NEW_ROOT"
```

Такой откат также требует отдельного разрешения. Повторный запуск завершённого
rollback проверяет receipt и actual state, не пересоздаёт server повторно.
Неизвестная попытка/изменённый контейнер или очередь destructive jobs дают STOP,
а не обход проверки. Прерванная initial configuration восстанавливается только
по своему private initialization journal и точным checksums; чужие файлы не
принимаются как состояние установщика.

## Приёмка и состояние очереди

Только disposable-фото и короткие видео с известными SHA-256: один/несколько,
phone-only/NAS-only/both, Gallery-only/device-only/everywhere, OS denial,
offline/restart, Live/Motion, chronological restore/альбомы, selective/Empty Trash,
RO external отказ, явно writable external удаление, cross-owner/shared originals
защита. Полная [русская инструкция пользователя](BUILD11-USER-MANUAL-RU.md)
содержит проверку интерфейса. Проверьте новую upload: thumbnail и preview должны
появиться, photo/video viewer — открыться. API и microservices должны работать.
Backup, search, faces, sharing, Memories/ML проверяются без full-library анализа.

Состояние production `backgroundTask` остаётся paused ради 21 сохранённых jobs.
Inline permanent deletion работает отдельно; автоматический срок корзины,
queued retries и derivative cleanup на HP **BLOCKED**, пока владелец отдельно не
одобрит review/activation очереди. Clean install с активной upstream queue
проверяется отдельно; установщик не имитирует production expiration PASS.

## Точные STOP и действия

| Код                                                                                 | Что делать                                                                                                                                     |
| ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `RELEASE_PACKAGE_FILE_CHANGED` / `PINNED_*`                                         | Не запускать. Снова скачать официальный пакет по immutable URL и сравнить опубликованный checksum; исходный state сохранить.                   |
| `COMPLETE_BUILD10_BRIDGE_FIRST`                                                     | Использовать отдельно одобренный exact-six bridge через общий `upgrade --complete-confirmed-cleanup`; не выдумывать completion receipt.        |
| `SIX_CONFIRMED_CLEANUP_COMPLETION_RECEIPT_REQUIRED_NO_REPLAY`                       | Завершение не доказано. Передать сохранённый private report владельцу; не удалять jobs и не повторять files вручную.                           |
| `NAS_RECOVERY_VERIFICATION_EXPIRED_NO_TIMESTAMP_REFRESH`                            | Выполнить настоящий snapshot export/content verification существующим NAS recovery инструментом. Не менять timestamp.                          |
| `INTERRUPTED_INSTALL_CONTEXT_CHANGED` / `*_CONFIGURATION_CHANGED`                   | Вернуть тот же подписанный пакет и неизменный private config; существующий state не редактировать. Другую конфигурацию installer не применяет. |
| `EXACT_NAS_NFS_SOURCE_AND_TARGET_REQUIRED`                                          | Сверить настройки нового сервера с действительным DSM export; production mounts не менять и не обходить проверку.                              |
| `NFS_WRITE_MODE_MUST_ALREADY_BE_EXPLICITLY_CONFIGURED`                              | Read-only mount не поддерживает writable режим. Оставить библиотеку read-only либо отдельно получить narrow NAS export authorization.          |
| `API_AND_MICROSERVICES_REQUIRED`                                                    | Текущая конфигурация API-only небезопасна. Сначала отдельное согласованное исправление effective Compose; release guard не отключать.          |
| `FRESH_RESTORED_BACKUP_EXPIRED` / `HISTORIC_RECOVERY_METADATA_UNPINNED_RUN_REFRESH` | Выполнить `refresh-recovery` с тем же state и настоящей свежей NAS evidence. Старые receipts/backups сохранить, timestamps не исправлять.      |
| `RECOVERY_RECEIPT_METADATA_CHANGED_RUN_REFRESH` / `RECOVERY_GENERATION_*`           | Сохранить private state и журнал: metadata/chain повреждены или изменены. Не удалять activation receipts и не подменять proof ради PASS.       |
| `RECOVERY_REFRESH_ALREADY_IN_PROGRESS`                                              | Подключиться к `tmux attach -t gallery-build11-refresh-recovery`; не запускать параллельный backup/restore.                                    |
| `EXISTING_APPLY_ATTEMPT_*` / health failure                                         | Не повторять apply автоматически. Использовать проверенный rollback выше с тем же state.                                                       |
| `PINNED_MACHINE_LEARNING_DEPENDENCY_REQUIRED`                                       | Нужен настоящий immutable upstream ML reference в пакете; mutable latest или произвольный локальный image не допускаются.                      |

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
