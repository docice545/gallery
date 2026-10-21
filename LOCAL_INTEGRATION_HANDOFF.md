# FOTO Build 17 — локальное объединение, backend и подписанная APK

Это воспроизводимая инструкция **для dev/integration**, не production deployment.
Cloud ветки не объединялись. Нельзя называть объединённую сборку проверенной до исполнения
команд на её точном локальном HEAD. APK/image этой новой совокупности исходников ещё не существуют.

## 1. Что получать

| Назначение                                                                                       | Ветка / PR                                                                         | Полный проверенный SHA                                         |
| ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Build 17 baseline: runner, duplicates/admission, клиенты, version/signing config                 | `codex/foto-build17-web-handoff`                                                   | `d7a31f3420b483974a7247613791cdbc395cacd4`                     |
| Редактор, локализация, source-only CI, evidence                                                  | `codex/foto-build17-editor`, [PR 4](https://github.com/docice545/gallery/pull/4)   | `cf2cca55b8187fbf91582048dc1ed6d4d1138ec2`                     |
| Повторный импорт/owner/group, offline reindex + intent barriers, mobile JOIN, source-only guards | `codex/foto-build17-dedup-acceptance`, https://github.com/docice545/gallery/pull/5 | `9cba0246791603e3ff1fbcffaa46e65124906522` — source checkpoint |

Документационный HEAD последней ветки указан в итоговом ответе/PR. Для воспроизводимой сборки
ниже намеренно объединяется **точный source checkpoint**, а не плавающий branch HEAD. Отчёты из
последнего documentation commit можно сохранить отдельно; они не меняют runtime.
Три отчёта: `EDITOR_ACCEPTANCE.md`, `DEDUP_NAS_ACCEPTANCE.md`, этот документ.
PR 1 — исторический NAS task/evidence, **не дополнительная обязательная feature-ветка** для
этих двух PR. Не вливать его или main повторно «для надёжности».

Локальные HP изменения, реальные `progress.md`, `pending-tasks.md`, manifest и код внешнего
`noodle-gallery-maintenance.py` не доступны в Cloud. В частности, старые `server/test/mappers.ts`,
`.bak`, BUILD11/FOTO logs могут остаться только на HP. Не считать их интегрированными.

## 2. Безопасное получение и порядок объединения

Владелец dev checkout, например `codex-gallery`, **не root**. `REPO` — фактический существующий
HP dev-репозиторий (ранее назывались `/mnt/hp-data/codex-work/gallery` и `foto-integration`;
Cloud не может подтвердить, какой из них сейчас канонический). Единственный обязательный ввод:

```bash
export REPO=/ПОЛНЫЙ/ПУТЬ/К/СУЩЕСТВУЮЩЕМУ/DEV/REPO
```

В обычной shell этого пользователя:

```bash
set -euo pipefail
umask 077
: "${REPO:?Укажите существующий dev checkout, не /opt/immich}"
REPO="$(realpath "$REPO")"
test "$(git -C "$REPO" rev-parse --is-inside-work-tree)" = true
test "$REPO" != /opt/immich
git -C "$REPO" remote get-url origin   # должен вести в docice545/gallery; SSH допустим
BASE=d7a31f3420b483974a7247613791cdbc395cacd4
EDITOR=cf2cca55b8187fbf91582048dc1ed6d4d1138ec2
DEDUP=9cba0246791603e3ff1fbcffaa46e65124906522
LOCAL_BEFORE="$(git -C "$REPO" rev-parse HEAD)"
STAGING="$(mktemp -d "$(dirname "$REPO")/foto17-local.XXXXXXXX")"
git -C "$REPO" status --porcelain=v1 --untracked-files=all > "$STAGING/hp-before.status"
git -C "$REPO" diff --binary HEAD > "$STAGING/hp-before.patch"
# Patch не содержит untracked: они остаются на прежнем месте, не удалять их.
printf '%s\n' "$LOCAL_BEFORE" > "$STAGING/hp-before.head"
for SHA in "$BASE" "$EDITOR" "$DEDUP"; do
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]
  git -C "$REPO" fetch --no-tags origin "$SHA"
  test "$(git -C "$REPO" rev-parse FETCH_HEAD)" = "$SHA"
done
git -C "$REPO" merge-base --is-ancestor "$BASE" "$EDITOR"
git -C "$REPO" merge-base --is-ancestor "$BASE" "$DEDUP"
WT="$STAGING/source"
INTEGRATION_BRANCH="integration/foto17-$(basename "$STAGING")"
git -C "$REPO" worktree add -b "$INTEGRATION_BRANCH" "$WT" "$LOCAL_BEFORE"
export REPO BASE EDITOR DEDUP LOCAL_BEFORE STAGING WT INTEGRATION_BRANCH
printf 'Dev worktree: %s\nPrevious local HEAD: %s\n' "$WT" "$LOCAL_BEFORE"
```

Проверить origin перед fetch; не переписывать remote/credentials. Не checkout/reset/clean старого
дерева, не autostash и не удалять `.bak`, untracked или checkpoints. Приватный `hp-before.patch`
может содержать локальные секреты: не публиковать и не добавлять его в Git.

Порядок в новом worktree: baseline → **вся ветка редактора** → **точный dedup checkpoint**.
Не cherry-pick только Stage 2. Выполнять по одному merge, каждый раз разбирать конфликты:

```bash
cd "$WT"
git merge --no-ff --no-commit "$BASE"
# Если есть конфликты — остановиться здесь, разрешить в ЭТОМ worktree и проверить diff.
# Если merge не нужен, Git сообщит Already up to date; пустой commit не создавать.
git diff --check
git status --short
# Когда MERGE_HEAD существует и diff проверен:
if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  git commit -m 'chore(integration): include verified FOTO Build 17 baseline'
fi
git merge --no-ff --no-commit "$EDITOR"
git diff --check
if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  git commit -m 'feat(integration): include reviewed FOTO editor'
fi
git merge --no-ff --no-commit "$DEDUP"
git diff --check
if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  git commit -m 'fix(integration): include verified dedup and timeline fixes'
fi
git status --short
git rev-parse HEAD | tee "$STAGING/integration-source.sha"
```

`set -e` останавливает блок при конфликте. Не выполнять остаток, пока unresolved paths не закрыты.
`git diff --check` не заменяет code review. Сохранённый source SHA ещё **не означает PASS сборки**.
Неопубликованные HP изменения перенести отдельным reviewed commit, только после просмотра их diff,
при необходимости `git apply --check` для выбранного приватного патча. Не накладывать `.bak` поверх
нового `asset.repository.ts`. Незнакомые HP изменения — обязательный отдельный review, а не автоперенос.

Вероятные конфликты:

- `.github/workflows/{build-mobile,gallery-build-mobile,docker,test}.yml`: editor-only и расширенный
  source-only guards; сохранить запрет build/sign/publish для **обеих** review-веток, обычные tests
  и поведение остальных веток. Не брать wholesale `ours/theirs`. Два набора scope tests должны PASS.
- `server/src/repositories/asset.repository.ts`, `server/test/mappers.ts`: сохранить owner locks,
  checksum admission, duplicateId mapping, guarded deletion/root identity и local HP изменения,
  которые действительно нужны после проверки. Ни один auth/root check не удалять.
- `mobile/lib/infrastructure/repositories/timeline.repository.dart`: scalar local lookup должен
  остаться до LIMIT/OFFSET; не чинить повтор карточки удалением SQLite/медиатеки.
- Editor source/translation keys: сохранить общий preview/export pipeline, Freezed и RU captions.
  Новых mobile/native/DB schema/API контрактов dedup patch не добавляет.

## 3. Инструменты и окружение

Pins из репозитория и фактически использованные версии:

| Инструмент     | Версия / источник                                                                               |
| -------------- | ----------------------------------------------------------------------------------------------- |
| Node / pnpm    | 24.21.0 / 11.24.0, root mise/packageManager                                                     |
| Flutter / Dart | 3.47.2 / 3.13.2, mobile/mise.toml и pubspec.yaml                                                |
| Полный JDK     | Temurin 21.0.2+13; нужен `javac`, не только JRE                                                 |
| OpenAPI        | oazapfts 7.5.0; generator engine 7.25.0 из open-api/openapitools.json                           |
| Android        | SDK 36, build-tools 36.0.0; NDK 28.2.13676358, CMake 3.22.1                                     |
| Gradle         | только `mobile/android/gradlew`, wrapper 8.14; не системный Gradle                              |
| Docker         | Engine + Compose v2 + BuildKit, Linux amd64 для HP                                              |
| Прочее         | Python3, Git, bash, patch, jq, ImageMagick, curl, tmux; pnpm lock и pubspec.lock без обновления |

Пути существующих SDK/cache/keystore определить на HP, **они не выводятся из SHA репозитория**.
Не создавать новый ключ, не скачивать ML-модели, не менять системные limits/маршруты. Достаточно
подготовленных Node/Flutter/JDK/Android SDK; точное облачное расположение не копировать на HP.

```bash
export JAVA_HOME=/ПУТЬ/К/СУЩЕСТВУЮЩЕМУ/JDK21
export ANDROID_SDK_ROOT=/ПУТЬ/К/СУЩЕСТВУЮЩЕМУ/ANDROID_SDK
export ANDROID_HOME="$ANDROID_SDK_ROOT"
# PATH должен уже содержать закреплённые node/pnpm/flutter/dart/openapi-generator-cli/oazapfts.
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
export NODE_OPTIONS=--max-old-space-size=3072
export GRADLE_OPTS='-Dorg.gradle.workers.max=1 -Dorg.gradle.parallel=false'
# Существующий cache оставить; не очищать ~/.pub-cache, ~/.gradle или build cache.
export FOTO_JAVA_TRUSTSTORE=/etc/ssl/certs/java/cacerts
node --version
pnpm --version
flutter --version
"$JAVA_HOME/bin/javac" -version
"$ANDROID_SDK_ROOT/build-tools/36.0.0/apksigner" version
```

Проверки не отключают TLS. HP canonical state — `/mnt/hp-data/codex-work/foto-integration-state`;
использовать его общий lock/history, не создавать пустую замену manifest. Не запускать Codex.
Запуски ниже последовательны. Для защиты от SSH disconnect сначала `tmux -L foto17-local new -s integration`;
возврат: `tmux -L foto17-local attach -t integration`. Отдельный tmux server наследует exports этой shell. Внутри tmux export переменных повторить при необходимости.

```bash
cd "$WT"
export STATE=/mnt/hp-data/codex-work/foto-integration-state
export RUNNER="$WT/tools/foto-automation/foto-stage-runner.py"
test -d "$STATE"
python3 "$RUNNER" --repo "$WT" --state "$STATE" session bash --noprofile --norc
# Теперь мы в supervised shell с существующим session/legacy lock. Это НЕ запуск Codex.
set -euo pipefail
stage() { python3 "$RUNNER" --repo "$WT" --state "$STATE" "$@"; }
```

Все следующие тяжёлые commands выполнять **в этой shell по очереди**. Runner stage не ждёт
бесконечно занятый lock, не делает автоматический OOM retry и сохраняет real receipts/logs.
После FAIL сначала изучить приватный log, исправить причину; один повтор через `--retry-failed`.
`--resume` допустим только для точного integrity-checked checkpoint; чужой/старый PASS не выдавать за новый.

## 4. Зависимости и генерация

Холодный pnpm workspace требует SDK до plugin-sdk: иначе injected copy не содержит `build/index.js`.
Следующий порядок реально воспроизведён в Cloud:

```bash
stage workspace-link
stage sdk-build
stage workspace-link
stage plugin-sdk-build
stage workspace-link
stage typecheck
# Generate Dart SDK из УЖЕ проверенного spec; не менять API ради редактора.
stage openapi-dart
stage flutter-dependencies
stage flutter-codegen
stage editor-codegen
stage editor-localize
stage flutter-analyze
```

`flutter-codegen` — существующий последовательный wrapper: Drift migration/schema generation,
build_runner `--low-resources-mode`, Pigeon по одному файлу, i18n loader/keys. Он может изменять
tracked generated outputs. Проверить diff, не удалять его для зелёного CI. `editor-codegen` делает
targeted Freezed; `editor-localize` генерирует переводы. Игнорируемые outputs не являются потерянными
исходниками и должны быть восстановлены штатными генераторами.

API здесь не менялся. Массовая перегенерация specs/SDK **не обязательна**; current spec уже содержит
optional nullable `AssetMediaResponseDto.duplicateId`. Если локальный merge действительно меняет DTO/API:

```bash
stage backend-build
stage openapi-spec
stage openapi-typescript
stage sdk-build
stage workspace-link
stage plugin-sdk-build
stage workspace-link
stage openapi-dart
stage flutter-dependencies
stage flutter-codegen
stage editor-codegen
stage editor-localize
stage flutter-analyze
```

Это реальные stages после объединения PR 4, не старые удалённые `make open-api`/`pnpm sync:open-api`.
Review diff `open-api/immich-openapi-specs.json`, `packages/sdk/src/fetch-client.ts`, mobile generated
contracts. В GitHub уже известен global OpenAPI drift: **не** принимать массовый diff автоматически.
Все secrets остаются вне Git. Для зависимостей использовать `--frozen-lockfile`/`--enforce-lockfile`,
как делают wrappers; не запускать upgrade или bootstrap последней произвольной версии.

## 5. Проверка объединённого исходника

Новые dedup cases плюс реальные БД/синтетический filesystem; никакой production DB URL:

```bash
python3 - "$WT" "$STATE" <<'PY'
import subprocess,sys
from pathlib import Path
root=Path(sys.argv[1])
files=sorted(str(p.relative_to(root/'server')) for p in (root/'server/src').rglob('*.spec.ts'))
assert files
for start in range(0,len(files),12):
 subprocess.run([sys.executable,str(root/'tools/foto-automation/foto-stage-runner.py'),
  '--repo',str(root),'--state',sys.argv[2],'unit',*files[start:start+12]],check=True)
PY
stage medium test/medium/specs/services/foto-duplicate-admission.spec.ts test/medium/specs/services/authorized-deletion.spec.ts test/medium/specs/services/trash-timeline.service.spec.ts test/medium/specs/services/duplicate.service.spec.ts
# В уже supervised shell: selected scanner cases без RAW/model fixtures, последовательно.
(cd server && NODE_OPTIONS=--max-old-space-size=3072 pnpm exec vitest --config test/vitest.config.medium.mjs run test/medium/specs/services/library.service.spec.ts --testNamePattern 'external content identity' --maxWorkers=1 --no-file-parallelism --maxConcurrency=1)
stage flutter-test test/infrastructure/repositories/foto_dedup_timeline_test.dart test/infrastructure/repositories/timeline_repository_test.dart test/infrastructure/repositories/trash_deletion_timeline_test.dart test/infrastructure/repositories/trash_local_sync_test.dart test/domain/services/sync_stream_service_test.dart test/medium/repositories/backup_repository_test.dart test/infrastructure/repositories/live_photos_timeline_test.dart
python3 -m unittest discover -s tools/foto-automation/tests -q
```

Medium globalSetup создаёт новый pinned PostgreSQL14 контейнер и применяет миграции туда.
`IMMICH_TEST_POSTGRES_URL` задаёт harness; **не** назначать ему production URL и не запускать
`schema:reset` против HP. Не отключать recovery-proof, fsync, ownership, root checks ради тестов.

Editor suites из evidence после локального merge надо запустить один раз, без повторов target files:

```bash
python3 - "$WT" "$STATE" <<'PY'
import json, subprocess, sys
from pathlib import Path
root=Path(sys.argv[1]); names=[]
for run in json.loads((root/'FOTO_BUILD17_EDITOR_EVIDENCE.json').read_text())['runs']:
    if run['stage']!='flutter-test': continue
    for arg in run['argv']:
        if arg.endswith('_test.dart') and arg not in names: names.append(arg)
assert names and all((root/'mobile'/n).is_file() for n in names)
subprocess.run([sys.executable,str(root/'tools/foto-automation/foto-stage-runner.py'),
               '--repo',str(root),'--state',sys.argv[2],'flutter-test',*names],check=True)
PY
stage flutter-analyze
git diff --check
```

Это новая проверка **merged HEAD**, не ненужное повторение неизменённой Cloud ветки.
Golden сравнивать на закреплённом SDK, без `--update-goldens`. Full analysis source-only dedup
ветки отдельно был FAIL из-за старого EditorState/missing Freezed: нельзя пропустить generation
или не включить PR 4. Android/Flutter native/HP combined E2E в Cloud этим не подтверждены.

## 6. Backend: компиляция и Docker image

В той же supervised shell:

```bash
stage backend-build
SOURCE="$(git rev-parse HEAD)"
test -z "$(git status --porcelain)"   # generated changes сначала review + commit, затем тесты на новом HEAD
printf '%s\n' "$SOURCE" > "$STAGING/final-source.sha"
BACKEND_SRC="$STAGING/backend-source"
mkdir "$BACKEND_SRC"
git archive "$SOURCE" | tar -x -C "$BACKEND_SRC"
# Официальная branding action вызывает именно этот script; только disposable build snapshot.
(cd "$BACKEND_SRC" && FORK_VERSION=5.7.3 BUILD_NUMBER=17 bash branding/scripts/apply-branding.sh)
(cd "$BACKEND_SRC" && bash branding/scripts/verify-branding.sh)
IMAGE="foto-server:build17-${SOURCE:0:12}"
export SOURCE IMAGE
DOCKER_BUILD=(docker build --platform linux/amd64 --file "$BACKEND_SRC/server/Dockerfile" \
  --build-arg BUILD_VERSION=5.7.3 --build-arg BUILD_REPOSITORY=docice545/gallery \
  --build-arg BUILD_SOURCE_COMMIT="$SOURCE" --build-arg BUILD_SOURCE_REF="$INTEGRATION_BRANCH" \
  --build-arg BUILD_IMAGE="$IMAGE" --build-arg BUILD_ID="local-${SOURCE:0:12}")
# Existing named targets: warm each independently, so final assembly reuses them.
# Do not add --no-cache or launch another build while this loop runs.
for TARGET in sdk plugin-sdk server web cli plugins; do
  "${DOCKER_BUILD[@]}" --target "$TARGET" "$BACKEND_SRC"
done
"${DOCKER_BUILD[@]}" --iidfile "$STAGING/backend-image.id" --tag "$IMAGE" "$BACKEND_SRC"
docker image inspect "$IMAGE" --format '{{.Id}}' | tee "$STAGING/backend-image.checked.id"
test "$(cat "$STAGING/backend-image.id")" = "$(cat "$STAGING/backend-image.checked.id")"
docker image inspect "$IMAGE" --format '{{json .Config.Env}}' > "$STAGING/backend-image.env.json"
python3 - "$STAGING/backend-image.env.json" "$SOURCE" <<'PY'
import json,sys
values=dict(v.split('=',1) for v in json.load(open(sys.argv[1])))
assert values['IMMICH_SOURCE_COMMIT']==sys.argv[2]
assert values.get('IMMICH_WORKERS_INCLUDE') not in ('api',)
assert values.get('IMMICH_WORKERS_EXCLUDE') not in ('microservices',)
PY
docker save --output "$STAGING/foto-server-build17.docker.tar" "$IMAGE"
sha256sum "$STAGING/foto-server-build17.docker.tar" > "$STAGING/backend.SHA256SUMS"
```

Docker daemon выполняет BuildKit workers вне cgroup shell/runner. Последовательный warm-up targets
снижает параллельную работу стадий, **но не устанавливает** лимит памяти/CPU самому daemon.
Эту Docker сборку выполнять на выделенном dev build-host/VM либо заранее проверенном изолированном
builder с лимитами. Актуальный безопасный builder HP здесь неизвестен; не считать shell MemoryMax
защитой production Docker daemon. Не менять systemd/Docker limits HP или останавливать Memories.
Это обязательное условие перед запуском Docker commands выше; при его отсутствии image build BLOCKED.

Dockerfile содержит server/API + microservices runtime, web build, CLI и WASM plugins. Базовые images
закреплены digest. Docker автоматически выполняет TS compilation/migration sync; отдельный «Immich»
backend или второй каталог не нужен. Branding snapshot не становится новым source commit.
При registry/API rate limit не обходить TLS/provenance и не менять image на `latest`.
`github_token` build secret поддержан Dockerfile, но не обязателен; если нужен — только существующий
локальный token через BuildKit secret, не ARG, не в журнал и не в Git. Его наличие Cloud не подтверждает.

Новый image реально собран только если docker build завершился, image ID совпал и последующий
isolated smoke PASS. Эти команды в Cloud на объединённом source **не выполнялись**, так как merge
запрещён. Не использовать старый image/APK как содержащий новые исправления.

## 7. Изолированный запуск backend и настройки NAS

НЕ использовать production `/opt/immich` Compose, его `.env`, volumes, named containers или БД.
Для non-production runtime нужен отдельный Docker host/VM либо специально проверенный dev daemon.
На действующем HP создание новых контейнеров/сетей — отдельное действие оператора; этот handoff
не выполняет и не разрешает production deployment. Существующие VPN/DNS/nginx/ML/Memories не менять.

Следующая команда создаёт **новый приватный JSON Compose и новые volumes**, а не ссылается на
несуществующий файл. Server image — точный ID только что построенного image; внешняя библиотека
содержит только синтетические originals и read-only mount. Host port по умолчанию loopback 22283.

```bash
export LAB="$STAGING/lab"
export LOCAL_IMAGE_ID="$(cat "$STAGING/backend-image.id")"
python3 - <<'PY'
import json,os,secrets
from pathlib import Path
root=Path(os.environ['LAB']);root.mkdir(mode=0o700)
for name in ['media','external','database']: (root/name).mkdir(mode=0o700)
(root/'gallery-config.json').write_text(json.dumps({'machineLearning':{'enabled':False},'trash':{'enabled':True}}))
password=secrets.token_hex(24)
p={'name':'foto17-local-'+root.parent.name.lower().replace('.','-'),'services':{
 'server':{'image':os.environ['LOCAL_IMAGE_ID'],'pull_policy':'never',
   'environment':{'DB_HOSTNAME':'database','DB_USERNAME':'postgres','DB_PASSWORD':password,
    'DB_DATABASE_NAME':'immich','REDIS_HOSTNAME':'redis','IMMICH_CONFIG_FILE':'/config/gallery.json'},
   'ports':['127.0.0.1:22283:2283'],
   'volumes':[str(root/'media')+':/data',str(root/'external')+':/external:ro',str(root/'gallery-config.json')+':/config/gallery.json:ro'],
   'depends_on':{'database':{'condition':'service_healthy'},'redis':{'condition':'service_healthy'}}},
 'database':{'image':'ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23',
   'environment':{'POSTGRES_USER':'postgres','POSTGRES_PASSWORD':password,'POSTGRES_DB':'immich'},
   'volumes':[str(root/'database')+':/var/lib/postgresql/data'],
   'healthcheck':{'test':['CMD-SHELL','pg_isready -U postgres -d immich'],'interval':'2s','timeout':'5s','retries':30}},
 'redis':{'image':'docker.io/valkey/valkey:9@sha256:c123e3715db63d06d4ad6964884037aa0d5d4d703939b9929954112889708e1d',
   'healthcheck':{'test':['CMD','redis-cli','ping'],'interval':'2s','timeout':'5s','retries':30}}
}}
(root/'compose.json').write_text(json.dumps(p,indent=2)+'\n')
(root/'compose.json').chmod(0o600)
PY
LOCAL_COMPOSE="$LAB/compose.json"
export LOCAL_COMPOSE
docker compose -f "$LOCAL_COMPOSE" config --quiet
# Только после проверки dev daemon и отсутствия production mounts:
docker compose -f "$LOCAL_COMPOSE" up -d --wait
curl --fail --silent --show-error http://127.0.0.1:22283/api/server/ping
curl --fail --silent --show-error http://127.0.0.1:22283/api/server/version
docker compose -f "$LOCAL_COMPOSE" logs --no-color server > "$STAGING/local-server.log"
```

Этот generated Compose имеет только syntax validation в Cloud, **не выполненный runtime smoke**.
Не публиковать Compose/config/logs с credentials. При ошибке сохранить их приватно, не менять
права всего SSD/NAS. Не использовать `down -v`, `--remove-orphans`, `privileged`, Docker socket mount
или production `DB_URL`. API и microservices остаются включены по умолчанию; проверить в private log
`Starting api worker`, `Starting microservices worker` и выполнение thumbnail/preview jobs.
Отсутствие ML sidecar здесь намеренное: реальные ML/Memories production задачи не тестируются.

В web открыть `http://127.0.0.1:22283`, создать **тестового** администратора и трёх новых пользователей.
В Admin → External Libraries создать каждому его `/external/<test-owner-directory>`; исходные
synthetic файлы поместить в соответствующие host directories до scan. Не подставлять UUID семьи.
Для mobile физического устройства нужен отдельный reachable dev HTTPS URL, доверенный сертификат
и проверенный port binding. Его адрес/cert/доступ из телефона в Cloud неизвестны: `DEV_SERVER_URL`
обязательно определить на месте. Не менять production reverse proxy, VPN, DNS или routing ради теста.

Managed files `/data/upload/<owner>` и external `/external` — разные scopes. Для реального NAS test
требуется отдельно выделенный synthetic каталог и существующий безопасный NFS mount. Этот пример
использует local FS и **не доказывает NFS**. NAS originals остаются источником истины внешней библиотеки;
managed upload находится на NAS только при подтверждённом bind mount. Превью/encoded motion могут
оставаться на SSD. Не расширять разрешённые roots до `/data` и не менять чужие scopes.

Permanent deletion в manual lab разрешать только штатной owner/admin flow с **настоящим подписанным
recovery-proof**, проверенными roots и свежими recovery inputs. Пользовательские policies не копировать
из production. Процедуры уже есть: `scripts/release/trash_recovery_inputs.py`,
`trash_recovery_evidence.py`, `server/src/utils/deletion-recovery.ts` и соответствующие `docs/`.
Их текущие inputs/operator provenance нужно определить для конкретной test storage, а не выдумать.
Medium deletion tests создают и проверяют disposable evidence отдельно от production; общий
129-case прогон предшествовал последней offline-index правке, финальные 15 admission + 6 scanner
прошли после неё. Это не доказательство настоящего Synology recovery.

## 8. Android release и существующая подпись

Сборка только после PASS объединённого source. В **том же supervised build shell**:

```bash
cd "$WT"
test "$(git rev-parse HEAD)" = "$(cat "$STAGING/final-source.sha")"
test -z "$(git status --porcelain)"
# В новом worktree keys не копировались. Не создавать и не читать их в Cloud.
test ! -e mobile/android/key.jks
test ! -e mobile/android/key.properties
unset PR_NUMBER ALIAS ANDROID_KEY_PASSWORD ANDROID_STORE_PASSWORD
stage android-apk
APK="$WT/mobile/build/app/outputs/flutter-apk/app-release.apk"
BT="$ANDROID_SDK_ROOT/build-tools/36.0.0"
export APK BT
unzip -t "$APK" > "$STAGING/apk-zip.log"
"$BT/aapt" dump badging "$APK" > "$STAGING/apk-badging.txt"
grep "package: name='de.opennoodle.gallery' versionCode='17' versionName='5.7.3'" "$STAGING/apk-badging.txt"
"$BT/zipalign" -c -P 16 4 "$APK"
if "$BT/apksigner" verify "$APK" > "$STAGING/unsigned-check.log" 2>&1; then
  echo 'STOP: expected unsigned artifact; verify signing origin locally' >&2
  exit 1
fi
grep -Eq 'Missing META-INF/MANIFEST.MF|No signatures|No signature' "$STAGING/unsigned-check.log"
sha256sum "$APK" > "$STAGING/android-unsigned.SHA256SUMS"
```

Release без ключа штатно unsigned, без debug fallback. Не выдавать его за installable production APK.
Существующий Gradle supports `mobile/android/key.jks` или storeFile из key.properties и env ALIAS/
ANDROID_KEY_PASSWORD/ANDROID_STORE_PASSWORD. Чтобы не копировать ключ в исходники и build logs,
используйте существующий HP-only `scripts/release/SignExistingApk.java` после сборки.

Обязательные **местные** значения: `KEYDIR` — фактический каталог действующих key.jks/key.properties,
`TRUSTED_APK` — заведомо подписанный тем же проектным ключом предыдущий APK. Cloud не имеет их путей,
содержимого или подтверждённого certificate fingerprint. Helper требует alias `foto` и storeFile,
разрешающийся в `KEYDIR/key.jks`. Если действующая конфигурация иная, **не переименовывать ключ**
и не создавать новый: остановить signing и отдельно проверить фактическую Gradle конфигурацию.

```bash
: "${KEYDIR:?Существующий локальный каталог project keystore}"
: "${TRUSTED_APK:?Заведомо доверенный предыдущий подписанный APK}"
python3 - "$KEYDIR" <<'PY'
import os,stat,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve(strict=True)
for name in ['key.jks','key.properties']:
 p=root/name;s=p.lstat()
 assert stat.S_ISREG(s.st_mode) and not p.is_symlink() and s.st_uid==os.getuid() and stat.S_IMODE(s.st_mode)==0o600
PY
SIGNED_APK="$STAGING/foto-build17-signed.apk"
sha256sum --check "$STAGING/android-unsigned.SHA256SUMS"
"$JAVA_HOME/bin/java" scripts/release/SignExistingApk.java "$KEYDIR" "$BT/apksigner" "$APK" "$SIGNED_APK"
sha256sum --check "$STAGING/android-unsigned.SHA256SUMS"
"$BT/apksigner" verify --verbose --print-certs "$SIGNED_APK" > "$STAGING/signed-cert.txt"
"$BT/apksigner" verify --verbose --print-certs "$TRUSTED_APK" > "$STAGING/trusted-cert.txt"
grep 'certificate SHA-256 digest:' "$STAGING/signed-cert.txt" | sed 's/^.*certificate SHA-256 digest: //' > "$STAGING/new-cert.sha256"
grep 'certificate SHA-256 digest:' "$STAGING/trusted-cert.txt" | sed 's/^.*certificate SHA-256 digest: //' > "$STAGING/old-cert.sha256"
test -s "$STAGING/new-cert.sha256"
cmp "$STAGING/new-cert.sha256" "$STAGING/old-cert.sha256"
python3 - "$WT" "$APK" "$SIGNED_APK" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1])/'scripts/release'))
import android_release
assert android_release.apk_payload(Path(sys.argv[2]))==android_release.apk_payload(Path(sys.argv[3]))
PY
"$BT/zipalign" -c -P 16 4 "$SIGNED_APK"
sha256sum "$SIGNED_APK" > "$STAGING/android-signed.SHA256SUMS"
# Не устанавливает APK и не удаляет данные приложения.
```

Перед установкой проверить application ID/version и подпись trusted APK. Только после этого
отдельно `adb install -r` на тестовом устройстве; не uninstall и не clear data. Native installation
не выполнялась Cloud. Прежний unsigned APK из 244ae32f **не содержит** editor/dedup patch.
Cloud delivery предыдущего APK была BLOCKED upload401; исходники доступны через GitHub fetch,
а эта локальная сборка не зависит от старой draft release или недоступного архива.

## 9. Обязательный реальный acceptance после локального запуска

Для каждого пункта сохранить version/source/image ID, owner, asset ID, пути, hashes, count до/после.
Только synthetic test users/media, никакого family archive. PASS/FAIL/NOT VERIFIED отдельно:

1. Один JPG на NAS + scan + повторный scan/импорт: один ожидаемый catalog ID, одна карточка,
   original hash неизменён. То же через два пути shared space/album; проверить count/пагинацию.
2. External-first → upload с телефона; mobile-first → scan. Убедиться, что managed backup реально
   существует до удаления local copy. Проверить ID/checksum algorithm, content hash и owner;
   разные самостоятельные server IDs не объединять по одному duplicateId/имени/дате.
   Отдельно переименовать только synthetic NAS-файл, выполнить offline indexing и новый scan:
   новая active запись видна, старая offline запись сохранена. Явный Trash/failed permanent-deletion
   intent должны по-прежнему блокировать воскрешение, в том числе по checksum alias после rename.
3. Отключить сеть во время upload, повторить после восстановления, перезапустить только test app/
   test server. Нет двойного managed original, «completed» только после действительного server ACK.
4. Три пользователя: одинаковые bytes не дают доступ к чужим файлам; shared album не меняет owner;
   отредактированная версия с разными bytes остаётся самостоятельной; favourite/album links целы.
5. JPG, MP4/MOV, Live Photo на раздельных NAS/SSD roots: Trash → Restore → Trash, original hashes,
   связь JPG/motion и thumbnails сохранены. Убийство процесса/обрыв NFS — только в disposable lab.
6. Permanent delete только одной synthetic пары после настоящей recovery preparation/owner consent:
   оба original удалены, receipt consistent; повтор безопасен, другой owner/library не затронут.
   Без proof/при revoked consent/NFS failure — отказ, отсутствие ложного PASS и сохранность файлов.
7. Android native deny → grant → retry; фон, force-stop/reboot и sync после resume. iPhone Photos
   permissions аналогично. Это нельзя заменить SQLite/native mocks.
8. Editor: восемь коррекций/32 фильтра/intensity; crop/rotate/flip; draw/text/sticker/layers,
   undo/redo/reset, zoom source coordinates, RU/safe-area/200%; Save creates ровно одну PNG,
   original hash/album/live pair не изменены. Backup этой PNG даёт новую запись и thumbnail/preview.
9. Live Photo проигрывается сразу в timeline после cold start/scroll/возврата/background; motion не
   появляется отдельной серой карточкой. Ручное редактирование Motion пары не включено.
10. Реальный AI E2E только с уже существующим разрешённым **non-production** sidecar. Модель не
    устанавливать. Production Memories/ML jobs и внешние maintenance timers не трогать.

## 10. Что остаётся FAIL/NOT VERIFIED

- Общий merged source и production database upgrade на HP здесь не запускались. Нужны предыдущие
  локальные patches и фактические mounts/overrides; неизвестные значения нельзя придумать.
- 131 diagnostics полного analyze dedup branch без старого Freezed; editor PR отдельно имеет полный
  analyze PASS. После merge обязателен fresh generation/full analyze, не подавление diagnostics.
- Исторический глобальный CI на editor checkpoint: ShellCheck 0.11.0 и branding-before-build assertion
  одинаково FAIL на базе; OpenAPI drift, SQL TestMigration drift, Web require-await и bits-ui
  Element-not-defined timer тоже FAIL, но полный baseline run последних четырёх не выполнялся.
  Подробности/логи — `FOTO_BUILD17_EDITOR_TEST_REPORT.md`. В этом задании они не объявлены исправленными.
- Две уже существующие независимые external/managed записи одинаковых bytes не становятся одной
  карточкой от одного optional duplicateId. Актуальный HP maintenance и пользовательские stack
  исключения не получены. Не создавать второй алгоритм и не включать Anna автоматически.
- Реальный NFS/Synology, native permissions/background, signing certificate и устройство — NOT VERIFIED.
- Новый объединённый image/APK отсутствует до локальных команд. Никакого product RELEASE READY.

## 11. Откат dev-интеграции и запусков

Неудачное объединение: оставить `$WT`, status/logs и conflict files для анализа. Исходный HP checkout
не переключался и остаётся на `$LOCAL_BEFORE`; untracked и локальные изменения сохранены на месте.
Для следующей попытки создать другой worktree от сохранённого SHA; не reset/clean/rebase/force-push,
не «чинить» конфликт откатом production. Завершённые локальные integration commits остаются в Git.

Неудачный isolated backend smoke: остановить **только lab server**:

```bash
docker compose -f "$LOCAL_COMPOSE" stop server
```

Сохранить его private logs/image ID и тестовую БД/volumes. Не удалять volumes, не делать manual SQL.
Старая версия приложения может быть несовместима с миграциями других HP patches: безопасный retry
запускает новый lab project с новой DB, либо восстановленный **lab backup** на отдельном PG instance.
Наличие совместимого production rollback этим не доказано; реальный HP rollout требует отдельного
read-only preflight, резервной копии, migration compatibility review и явного разрешения владельца.

Закрыть supervised shell `exit`, затем tmux. Checkpoints не удалять. После реального PASS локального
HEAD обновить существующие HP progress/pending **добавлением** результатов; manifest через штатный
`foto-manifest.py --check` и crash-safe transaction, как описано в editor HP handoff. Cloud отчёты
не являются заменой canonical manifest и не должны его перезаписывать.

## Дополнение: полный backend unit suite без перегрузки коллектора

Расширенный Cloud запуск сразу 215 specs исчерпал Node heap 3072 MB при collection. Зависший
Vitest parent остановлен сигналом только проверенному runner; supervisor убрал его дерево.
Это реальная ошибка лимита V8 в Cloud, **не** подтверждение OOM/его исправления на HP.
Системные лимиты не повышались; тот же полный запрос автоматически не перезапускался.

Для полного набора на объединённом HEAD использовать небольшие последовательные requests,
с checkpoints runner для каждого пакета. Полный unit request из раздела 5 уже разбит на такие пакеты; ниже тот же шаблон для справки, повторно его не выполнять:

Единственная исполняемая команда полного unit набора находится в разделе 5; не запускать её второй раз.

Не запускать сначала весь unit suite одним процессом и затем повторять все batches.
После FAIL/OOM не повышать MemoryMax/heap, не делать бесконечный retry: сохранить receipt и
диагностику, проверить отсутствие оставшегося дерева через supervisor, продолжать только
после конкретной коррекции. Уже прошедшие chunks допускают штатный integrity-checked `--resume`.

Полная server formatting проверка в Cloud также FAIL в двух byte-identical baseline файлах:
`server/src/schema/migrations-gallery/1793400000000-FixMemoryCandidateSchema.ts` и
`server/src/utils/recovery-evidence.spec.ts`. Это воспроизводимые замечания Prettier; их hash на
`d7a31f3420b483974a7247613791cdbc395cacd4` совпадает с текущим. Миграция Memories и recovery checks
не менялись ради зелёного CI. Новый GitHub `Test & Lint Server` check FAIL на шаге `ci-unit`;
raw job log недоступен из Cloud из-за policy denial log-storage host, поэтому его точная
внутренняя ошибка не объявлена установленной по предположению. Локальные результаты полных
unit batches и formatting публикуются отдельно.

После настоящих локальных PASS (не сейчас в Cloud) команда существующего manifest updater:

```bash
CANON=/mnt/hp-data/codex-work/foto-integration.manifest.json
MIRROR=/mnt/hp-data/codex-work/foto-integration-state/manifest.json
python3 tools/foto-automation/foto-manifest.py --check "$CANON" "$MIRROR"
python3 tools/foto-automation/foto-manifest.py "$CANON" "$MIRROR" \
  "$(git rev-parse HEAD)" "$(git branch --show-current)" "$STATE"
```

При missing/diverged/corrupt history остановиться, сохранить existing transaction files, не создавать
пустые manifests. В progress/pending добавить только реально завершённые этапы, фактические SHA,
пути к артефактам и оставшиеся native/NFS gates. Не помечать signing/device acceptance завершёнными
на основании Cloud mocks или неподписанной APK.

Результат расширенного Cloud-прогона на `fb3d89d1aeed42f92a6282a933a0b755d9dd5865`: **6878 PASS, 12 SKIP**, 213 specs полностью PASS,
1 MinIO/S3 spec пропущен штатным opt-in guard, 1 SharedSpace spec остаётся resource-BLOCKED.
Большой `shared-space.service.spec.ts` исчерпал 3072 MB и отдельно, и на неизменённой базе
`d7a31f3420b483974a7247613791cdbc395cacd4` с теми же dependency links/Node/Vitest. Это подтверждённая
базовая проблема выполнения этого spec при данном безопасном лимите, не новый assertion FAIL дедупликации. Не выдавать
6878 за полный PASS всего server suite; не поднимать лимиты ради зелёного результата.

После финальной server-правки `9cba0246791603e3ff1fbcffaa46e65124906522` повторены только затронутые
admission (15 PASS), выбранные scanner (6 PASS / 70 filtered SKIP), scoped unit (223 PASS),
TypeScript, ESLint и форматирование изменённых файлов. Flutter runtime с момента 240 PASS не менялся.
Все исходные runner receipts сохраняют настоящий HEAD + dirty-tree digest на момент запуска;
они не переписаны под финальный commit. На merged HP HEAD нужны новые собственные receipts.

Исторические evidence hashes относятся к указанным Cloud commits. После разрешённого локального
merge некоторые CI/source hashes закономерно меняются; не переписывать старые receipts, чтобы
они «совпали». Сохранить их как историю, review diff и записать настоящие проверки merged HEAD.
