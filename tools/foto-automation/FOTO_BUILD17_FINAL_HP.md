# FOTO Build 17: продолжить сборку после memory gate на HP

Это продолжение **уже подготовленного** backend image/APK release, **без deployment**.
Запускает doctoriceadm. В checkpoint подтверждены **50 обязательных PASS**, а не
49 (исправлено оператором после чтения manifest). `testsComplete` содержит все
50 имён; прежний runtime SHA256:
`c460031cab860039d7017459d1fa42ee13261e9ddb35fe75c637ee96b795e7bf`.
Сборка остановилась **до** `backend-image`, без RUNNING/FAIL build receipt.

Новый memory gate: backend требует `MemAvailable >= 10 GiB`, `MemTotal >= 14 GiB`
(минимум 4 GiB физической RAM вне уже существующего потолка BuildKit10GiB),
ограниченные PSI some/full (таблица ниже) и минимум 10 GiB headroom относительно каждого
конечного memory.max/memory.high текущего cgroup и всех видимых предков.
Неполные/нечитаемые наблюдения — STOP. Swap не засчитывается как RAM.
У остальных этапов прежние 5 GiB available / 6 GiB caller-limit floor.
10 GiB BuildKit — потолок, не заранее выделенная память; это консервативная
проверка допуска, **не доказательство устранения реального OOM**. Нагрузка после
допуска может измениться. Лимиты10g/12g и max-parallelism1 остаются прежними.

PSI указывается в **процентах времени**, не в долях единицы. Все шесть значений
проверяются отдельно у хоста и каждого видимого cgroup; усреднения между ними нет.
Любое превышение запрещает сборку. Границы включены:

| PSI | avg10 | avg60 | avg300 |
| --- | --- | --- | --- |
| some | 1.00% | 0.50% | 0.25% |
| full | 0.10% | 0.05% | 0.02% |

`some` означает ожидание хотя бы одной задачи, `full` — остановку всех активных
задач из-за памяти. Поэтому full ограничен значительно строже, а длинные окна
имеют меньший бюджет для устойчивого давления. Низкие остаточные значения HP
`some=0.00/0.03/0.02`, `full=0.00/0.01/0.00` допустимы; прежнее требование
точного нуля было излишне строгим. `total` — исторический счётчик, не текущий PSI.
Missing/malformed/duplicate/negative/nonfinite PSI по-прежнему запрещён.
Данные перечитываются и в launcher preflight, и в `stage('backend-image')`
непосредственно перед сохранением build intent/запуском команды.

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
Канонический launcher теперь отдельный файл `foto-build17-release-hp.sh`, а не
копируемый из Markdown многоуровневый heredoc. Блок скачивает точные LF-байты
из закреплённого коммита, проверяет SHA256 и Bash syntax до выполнения.
У launcher проверены также все вложенные Python heredoc и внутренний BUILD_ONLY
Bash. Это синтаксическая/fixture-проверка в Cloud, не исполнение команд на HP.

```bash
bash <<'HP'
set -euo pipefail
umask 077
FOTO_LAUNCH=$(mktemp /tmp/foto17-psi-launch.XXXXXXXX.sh)
FOTO_REF=4fd26568d5352eb822a01c241f7d858e37bce974
FOTO_PATH=tools/foto-automation/foto-build17-release-hp.sh
FOTO_LAUNCH_SHA=075d7f723123b50bfa34863ac281a6109a853b9a1657c63742ff8019c38b8188
sudo -u codex-gallery -H gh api "repos/docice545/gallery/contents/$FOTO_PATH?ref=$FOTO_REF" --jq .content | base64 --decode > "$FOTO_LAUNCH"
echo "$FOTO_LAUNCH_SHA  $FOTO_LAUNCH" | sha256sum --check -
bash -n "$FOTO_LAUNCH"
bash "$FOTO_LAUNCH"
HP
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
sudo -u codex-gallery -H tmux -L foto17-psi-build attach -t foto17-psi-build
```

Сессия сохраняет pane после выхода программы. Exit status:

```bash
sudo -u codex-gallery -H tmux -L foto17-psi-build display-message -p -t foto17-psi-build '#{pane_dead_status}'
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

PSI follow-up: 6 адресных тестов PASS, включая подтверждённый низкий профиль HP
при 11.11GiB available на синтетических host/cgroup файлах, точные границы всех
шести лимитов и превышение на0.000001, различие some/full, malformed/NaN/Inf,
давление в отдельном предке/cgroup, перечитывание наблюдений и STOP до child/build
intent при росте PSI после успешного preflight. Две launcher-проверки PASS:
Bash/BUILD_ONLY и все5 Python heredoc, LF без CRLF, закреплённые5 file hashes,
полный/повреждённый checkpoint без записи. EXIT handler сохраняет0/7; отдельный launcher проходит ShellCheck0.11.0 без suppression. AST класса Pipeline и non-PSI gates
совпадает с предыдущим HEAD:50-PASS reuse, signing, memory/cgroup limits, locks
и непосредственный stage-entry recheck не изменены. Ни один HP-тест не запускался.

Предыдущий memory/reuse/launcher update: 17 адресных тестов PASS (16 новых, один прежний memory test)
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
