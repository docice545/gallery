# FOTO: последовательные проверки и безопасное продолжение

Рабочая Cloud-ветка: `codex/foto-build17-web-handoff`, исходный SHA
`2315ae789a3824c7a60dc688e541c30648385e03`. Существующие HP checkout, manifest,
`progress.md`, `pending-tasks.md`, незакоммиченный `server/test/mappers.ts` и
`asset.repository.ts.bak` не заменяются этими инструментами. Их содержимое в Cloud неизвестно.

## Что защищено технически

- Все управляемые тяжёлые этапы используют один **неблокирующий flock**
  `foto-integration-state/heavy-stage.lock`. Второй запрос получает `STOP BUSY`, а не очередь запусков.
- Отдельный `codex-session.lock` общий для обоих launcher. Повторный запуск не запускает второй
  Codex и не перезаписывает промпт действующей сессии. Существующие legacy locks сохранены.
  Оба входа также берут legacy `gallery-build15-auto/auto.lock`; отсутствующий IPC lock создаётся
  без manifest/history и без замены существующего inode. Вложенный continuation не может
  переиспользовать унаследованный marker родительской сессии: проверяется PID входного процесса.
- Vitest: один worker, без параллельных файлов, `maxConcurrency=1`, только явно названные specs.
  Flutter tests: `--concurrency=1`. Gradle: один worker, без parallel/daemon, JVM 2 GiB,
  Kotlin compiler in-process. Node heap остаётся 3072 MiB.
  CPU affinity дочернего дерева ограничена двумя доступными CPU; `GOMAXPROCS`, Rayon и UV
  также ограничены. Это ограничение конкретного процесса, не изменение системных лимитов HP.
- Linux supervisor создаёт отдельную process group, обрабатывает INT/TERM/HUP, затем TERM/KILL,
  усыновляет и завершает также отделившиеся дочерние процессы через subreaper/pidfd.
- В systemd остаются **MemoryMax=8G, MemorySwapMax=1G, CPUQuota=200%** и все ограничения доступа.
  Добавлены `KillMode=control-group`, `OOMPolicy=stop`, `Restart=no`, `TimeoutStopSec=15s`.
  SIGKILL/OOM самого supervisor обрабатывает cgroup, поскольку SIGKILL нельзя перехватить в Python.
- Нет автоматического повтора неуспешного или незавершённого этапа. Даже после освобождения lock
  требуется явный `--retry-failed`. Launcher останавливается на кодах 134/137/143 и OOM-сообщениях.
- Успешные этапы сохраняются отдельно от HP manifest: исходный HEAD, digest изменений,
  команда, установленные зависимости, результат, приватный лог и его SHA-256. `--resume`
  использует только совпадающий checkpoint. Повреждение, symlink или изменение лога блокируют reuse.
  Для сборок дополнительно сверяются SHA-256 обязательных выходных файлов.
- Manifest сохраняет неизвестные поля и всю существующую history. Перед обновлением создаётся
  приватная transaction с состояниями before/after; оба файла заменяются через fsync + rename.
  При разрыве между заменами возобновление Codex блокируется до явного восстановления transaction.

Это граница **управляемых запусков**: произвольные команды, вручную запущенные вне runner, не
становятся ограниченными автоматически. Прямой запуск Vitest/tsc/Flutter/Gradle из Codex запрещён
в рабочем протоколе. Не запускайте одновременно сторонний launcher или ручные сборки HP.
Инструменты не меняют системные лимиты и сами не запускаются после установки.

## Использование runner

Команды выполняются от `codex-gallery`, после остановки предыдущей сессии штатным TERM/systemctl
для её конкретного unit. Не удаляйте lock-файлы: это создаёт другой inode и обходит flock.

```bash
RUNNER=/mnt/hp-data/codex-work/foto-integration-state/foto-stage-runner.py
python3 "$RUNNER" --resume unit src/services/asset-media.service.spec.ts
python3 "$RUNNER" --resume typecheck
python3 "$RUNNER" --resume medium test/medium/specs/services/library.service.spec.ts
python3 "$RUNNER" --resume flutter-test test/unit/domain/services/asset_service_test.dart
```

Последний путь Flutter — пример: передайте реально существующий `_test.dart` из текущей ветки.
Нельзя передавать произвольную shell-команду или добавлять `--maxWorkers=8`.
Medium tests разрешены только с **изолированным** Docker/PostgreSQL. Никогда не подставляйте HP
production DB/Redis/NAS в окружение тестов. При недоступности fixture тест остаётся FAIL/BLOCKED.

После диагностики причины ошибки оператор может **один раз** выполнить тот же этап с
`--retry-failed`. Это не фоновой retry loop. Не повторяйте OOM без исправления причины.
`dependencies` устанавливает закреплённые зависимости server с frozen lockfile;
`backend-build`, `flutter-analyze`, `android-apk` также используют общую блокировку.
`android-apk` до запуска Gradle требует полный `JAVA_HOME/bin/javac` (JRE недостаточно).
Java/Gradle используют уже настроенный `HTTPS_PROXY`, без переноса его credentials в argv.
Если изолированный JDK не содержит CA платформы, `FOTO_JAVA_TRUSTSTORE` может указывать на
существующий доверенный Java truststore; проверка TLS при этом не отключается.
Для холодного workspace доступны `sdk-dependencies`, `sdk-build`, `workspace-link`,
`plugin-sdk-build`. После сборки workspace SDK выполняется `workspace-link`, чтобы pnpm обновил
injected dependencies. Контракты обновляются через `openapi-spec`, `openapi-typescript`,
`openapi-dart` только при подтверждённом изменении API. `flutter-dependencies` использует
`--enforce-lockfile`, а `flutter-codegen` выполняет официальные генераторы последовательно,
включая Pigeon без `xargs -P4` и build_runner с `--low-resources-mode`.

Runner выводит только статус и путь к приватному логу. В логах тестов могут быть пути fixtures;
не публикуйте необработанные HP-логи/manifest. История прежних попыток остаётся в `stages/`.

## Перенос на HP без запуска Codex

1. Получите опубликованный commit в существующий репозиторий через `git fetch origin
   codex/foto-build17-web-handoff`. Это не checkout/reset и сохраняет локальные изменения.
2. Извлеките **только** `tools/foto-automation` из проверенного commit через `git archive` в новый
   приватный staging-каталог. Не накладывайте архив на HP working tree.
3. Проверьте `bash -n` трёх launcher и `foto-prompt-entry.sh`; выполните `python3 -m unittest
   discover -s <staging>/tools/foto-automation/tests -v` на временных fixtures.
4. При отсутствии активных сессий сохраните копии текущих launcher с уникальным именем.
   Установите `foto-stage-runner.py`, `foto-manifest.py`, `foto-prompt-entry.sh`, `foto-mobile-codegen.sh` и
   `foto-integration-continue-v2` в **существующий**
   `/mnt/hp-data/codex-work/foto-integration-state/`, owner/group `codex-gallery`, mode 0700.
   Установите два wrapper в их прежние `/usr/local/bin/` с owner root, mode 0755.
   Не копируйте Cloud state/manifest, не удаляйте старые checkpoints и backup-файлы.
5. Проверьте `codex-foto-continue --dry-run`. Он не запускает Codex.
   Реальный старт — отдельное ручное действие; эта инструкция не разрешает автоматический запуск.

Здесь нет deployment, Docker host grants, production SQL, изменения NFS/retention или доступа
к signing key. Не меняйте HP локальные пути/ветку автоматически: launcher по-прежнему требует
свою `codex/foto-integration` и проверенный HP manifest. Интеграция кода из Cloud в эту ветку
проводится после ручного review локальных незакоммиченных файлов, без reset/clean.

## Восстановление незавершённого обновления manifest

После остановки сессии и проверки пути transaction из её run-directory:

```bash
python3 /mnt/hp-data/codex-work/foto-integration-state/foto-manifest.py \
  --recover /ABSOLUTE/EXISTING/RUN/manifest-transaction-FULL_HEAD.json
```

Используйте **существующий** файл transaction, не создавайте его вручную. Recovery допускает
только точные before/after состояния, проверяет их hashes и не дописывает history второй раз.
Независимо изменённый manifest, некорректный JSON или не-приватный файл приводят к STOP с сохранением
всех файлов. Не правьте `expected_head` вручную ради PASS.

## Граница подтверждений

Автотесты используют реальные временные Linux-процессы/flock/signals/pidfd и искусственные
Git-репозитории. SIGKILL в дочернем процессе моделирует OOM-exit, **не реальное исчерпание RAM**.
Фактический systemd OOM/cgroup на HP, production fixtures и поведение физического Android
должны быть проверены отдельно оператором. Эта документация не является заявлением о готовности APK.
