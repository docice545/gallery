# Build 11: фактическая проверка установочного пакета

`scripts/release/build11_installation_smoke.py` запускается **только на отдельном
одноразовом Linux GitHub Actions runner** с пустым Docker daemon. На HP этот
тест запускать нельзя. Он не использует production PostgreSQL, фотографии,
NAS mounts, ключи подписи APK или recovery evidence владельцев.

CI закрепляет Docker CE и CLI 28.4.0 из существующего подписанного официального
APT repository Ubuntu 24.04. До любых fixture containers проверяются точная
версия обоих компонентов, стандартный `/var/run/docker.sock`, API 1.49+ и
наличие `image inspect --platform`. Затем выполняются настоящие classic и
containerd проверки. Custom daemon/context не используется. Это изменение
касается disposable CI VM: Docker на HP не обновляется этим workflow.

Run `38509927962` выявил прежнюю причину отказа: CLI/daemon API 1.48,
`DOCKER_PLATFORM_FLAG_UNSUPPORTED`. Новый prerequisite gate отклоняет такой
runtime до загрузки образов/создания конфигурации вместо непрозрачного STOP.
Проверки pinned index, amd64 manifest и config не заменяются fallback.

Установочный пакет предназначен для **linux/amd64**. Его сгенерированный
Compose закрепляет Valkey9 непосредственно на уже проверенном AMD64 manifest
`sha256:67878c70fc179bb928b1a9b510860aff1c475ff245e91d98d4b2133326bf8e3e`,
с config `sha256:c439a6b7b7dfe74b25d78f9e5d27fbaeb761f676de82eb1a154c5b719a8cfb3e`.
Это выбранный child upstream index
`sha256:c123e3715db63d06d4ad6964884037aa0d5d4d703939b9929954112889708e1d`:
SHA256 index, manifest и config проверены по реальным registry bytes.
Source `docker/docker-compose.yml` сохраняет upstream index; изменяется одна
точная image line в generated package, её provenance записывается в sealed
`release-operator.json`. Existing HP upgrade сохраняет текущий Redis container.
PostgreSQL reference и проверки index/config/selected platform сохраняются.

Proof38520267120 показал, что Docker28.4/containerd возвращает Valkey index
без доступного child даже после exact platform pull. Installer остановился
`PINNED_PUBLIC_DEPENDENCY_PLATFORM_CONTENT_REQUIRED`, до service start.
Прямой immutable pin той же AMD64 платформы проходит обычные RepoDigest,
Descriptor, config/manifest, OS/architecture и `--platform` проверки.
Фактический installation PASS можно заявлять только после нового CI результата.

После сборки и проверки backend/APK/IPA, реального rollback HTTP smoke и
создания предварительного пакета workflow выполняет:

```bash
export GALLERY_ISOLATED_CI=1
python3 scripts/release/build11_installation_smoke.py \
  "$RUNNER_TEMP/gallery-build11-package" \
  "$RUNNER_TEMP/build11-installation-lab.json"
```

`GITHUB_ACTIONS=true` задаётся самим GitHub Actions. Требуется существующая
авторизация `sudo -n docker`, обычная для одноразового GitHub runner. Скрипт
принудительно выбирает локальный `/var/run/docker.sock`, отбрасывает remote
Docker context/TLS environment и прекращает работу при любом существующем
контейнере, Gallery volume или Gallery network. Никакого global prune нет.

Пакет сначала полностью проверяется по `SHA256SUMS`, версиям, source и
rollback receipt. Используются настоящие исполняемые файлы из этого пакета.
Поддельный или изменённый пакет не запускается. Отчёт создаётся только в
новом файле с правами 0600; существующий отчёт не перезаписывается.

## Проверяемые операции

1. Реальное создание конфигурации штатным `gallery_install.py`, прерывание
   перед записью плана, безопасное продолжение без изменения конфигурации.
2. Реальное создание PostgreSQL, Redis, ML и Gallery через Compose, прерывание
   перед завершением health phase, штатное продолжение и повторная проверка
   без пересоздания контейнеров.
3. Реальная чистая установка с локальным managed-хранилищем; HTTP signup,
   login, upload, альбом и второй пользователь, thumbnail и preview jobs.
4. Настоящий `gallery-rollback.sh --fresh-install`, сохранность оригиналов и
   повторный запуск без повторного rollback.
5. Представительный Build 10 fixture: исходный compiled fallback, прежняя
   схема до единственной additive migration, приватные managed/external
   bind mounts и 27 paused BullMQ jobs. Шесть синтетических FileDelete jobs
   намеренно **не выполняются**. Все 27 payload hashes, порядок и шесть
   синтетических оригиналов сохраняются.
6. Настоящие `image_release.plan/execute` и миграция, отказ после запуска
   обновлённого контейнера, затем штатный hardened rollback. Во время теста
   работают настоящие PostgreSQL, Redis, Docker и HTTP; заменяется только
   точка искусственного health interruption.
7. Single/bulk Trash/Restore и исходные capture dates, managed consent и
   revocation, физическое удаление синтетических файлов, изоляция другого
   владельца, read-only external default, явный writable consent, mixed-scope
   отказ до первого удаления и Empty Trash после согласия.
8. Сохранность upstream идентификаторов, ownership, альбомов, offline index
   tombstone, томов, сетей, environment и отдельного постороннего контейнера.
9. После появления реальных owner storage policies в уже обновлённой
   синтетической базе: новый SQL/gzip backup через packaged
   `trash_predeploy.fresh_backup`, восстановление **именно этих байтов** через
   `restore_exact` в отдельный PostgreSQL `--network none`, anonymous volumes,
   без NAS mounts и внешних подключений. Compiled candidate и hardened fallback
   запускают только миграции на восстановленной копии. Проверяются полный
   ledger, fingerprints строк, включая `authorizationMode`, и сохранность
   managed/external storage policies. Ни один worker, файл оригинала или
   production recovery-proof при этом не используется. Очередь, контейнеры,
   mounts и синтетические originals работающего lab остаются неизменными.

Финальный пакет требует отдельный результат
`alreadyUpgradedFreshBackupRestore=true`; отсутствие этой проверки, отказ
restore или попытка использовать старую квитанцию блокируют публикацию.

Для представительного upgrade используется общий production image-only
engine с **настоящей read-only проверкой очереди fixture**. Это не проверка
HP-specific `build11_operator` с реальными backup/NAS/six-cleanup receipts;
никакие такие квитанции не создаются и не подделываются.

## Что отчёт не доказывает

Внешняя библиотека теста использует отдельный локальный synthetic bind mount,
не NFS. Это не утверждение о root squash, ACL или восстановлении Synology.
Чистая установка проверяется с local managed storage; NFS configuration
validator не обходится фиктивными mount reports. Квитанции восстановления,
production шесть старых deletion jobs, физические Samsung/iPhone и подписи
мобильных приложений остаются отдельными operator gates.

`PASS` появляется только после всех фактических фаз и успешной cleanup
собственных ресурсов. Ошибка любой фазы либо cleanup означает `FAIL` и exit 1.
Поля `productionChanged`, `productionNfsVerified`, `hpRecoveryEvidenceVerified`,
`physicalAndroidIosVerified` и `hpSixLegacyCleanupExecuted` всегда false.

Unit tests `test_build11_installation_smoke.py` проверяют границы безопасности,
отказ на чужих ресурсах, изменение queued payload/order, path traversal и
точное распознавание fault injection. Их успешный результат **не является**
доказательством успешной установки. Для этого нужен настоящий CI JSON report.
