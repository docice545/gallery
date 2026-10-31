# FOTO Build 24 — сборка на HP и обновление Samsung

Эта инструкция меняет только Android APK. Production backend HP уже
работает как `5.7.3`; его пересборка, перезапуск и миграции не требуются.

Исходный SHA Build 23: `a769b7d5982c90fbc6cd68c2a2aa5f4ebd33df25`.
Новая ветка: `codex/foto-build24-checkpoint-recovery`. Используйте **итоговый
40-символьный SHA из поставки**, для которого успешно завершился workflow
`FOTO Build 24 SQLite recovery`.

## Сборка владельцем HP

Используются существующие checkout `/opt/gallery-fork`, SSD-кеши, приватный
release keystore и [ограниченный runner](../../tools/foto-automation/README.md).
Новый ключ не создаётся и никуда не передаётся. Команды Cloud на HP не выполняет.

Сначала активируйте существующие Flutter **3.47.2**, JDK **21.0.2**, Node и pnpm
по pins репозитория. Не заменяйте toolchain/кеши сервера и не печатайте содержимое
`key.properties`. Если рабочий checkout имеет изменения, команды останавливаются.

```bash
set -euo pipefail
umask 077
foto_repo=/opt/gallery-fork
foto_state=/mnt/hp-data/codex-work/foto-integration-state
foto_sha=${FOTO_RELEASE_SHA:?Укажите итоговый опубликованный SHA Build 24}
[[ "$foto_sha" =~ ^[0-9a-f]{40}$ ]]
cd "$foto_repo"
test -z "$(git status --porcelain)"
(
  flock -n 9
  git fetch origin refs/heads/codex/foto-build24-checkpoint-recovery:refs/remotes/origin/codex/foto-build24-checkpoint-recovery
  git cat-file -e "$foto_sha^{commit}"
  git merge-base --is-ancestor "$foto_sha" refs/remotes/origin/codex/foto-build24-checkpoint-recovery
  git switch --detach "$foto_sha"
) 9>"$foto_state/heavy-stage.lock"
test "$(git rev-parse HEAD)" = "$foto_sha"
rg '^version: 5\.7\.3\+24$' mobile/pubspec.yaml
flutter --version
"${JAVA_HOME:?Используйте установленный JDK}/bin/javac" -version
export FOTO_PUB_OFFLINE=1
foto_runner="$foto_repo/tools/foto-automation/foto-stage-runner.py"
for foto_stage in openapi-dart flutter-dependencies flutter-codegen flutter-analyze; do
  python3 "$foto_runner" --repo "$foto_repo" --state "$foto_state" --resume "$foto_stage"
done
python3 "$foto_runner" --repo "$foto_repo" --state "$foto_state" --resume flutter-test \
  test/data/db test/pages/common/sqlite_recovery_page_test.dart \
  test/pages/common/sqlite_fresh_backup_review_test.dart \
  test/pages/common/sqlite_recovery_server_page_test.dart \
  test/widgets/settings/cloud_media_settings_test.dart \
  test/infrastructure/repositories/sqlite_sync_recovery_test.dart \
  test/infrastructure/repositories/sqlite_sync_recovery_file_test.dart \
  test/domain/utils/background_sync_test.dart
test -s mobile/android/key.properties
test -s mobile/android/key.jks
python3 "$foto_runner" --repo "$foto_repo" --state "$foto_state" --resume android-apk
foto_apk="$foto_repo/mobile/build/app/outputs/flutter-apk/app-release.apk"
test -s "$foto_apk"
foto_signing=$(apksigner verify --verbose --print-certs "$foto_apk")
printf '%s\n' "$foto_signing"
printf '%s\n' "$foto_signing" | rg -iq '^Signer #1 certificate SHA-256 digest: ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18$'
foto_badging=$(aapt dump badging "$foto_apk")
printf '%s\n' "$foto_badging"
printf '%s\n' "$foto_badging" | rg "^package: name='de.opennoodle.gallery' versionCode='24' versionName='5.7.3'"
sha256sum "$foto_apk"
git diff --exit-code -- mobile/pubspec.yaml mobile/pubspec.lock mobile/android/app/build.gradle
```

Если существующий ключ настроен по другому пути, проверяйте фактическую локальную
конфигурацию; не копируйте и не заменяйте ключ. Runner сохраняет ограничение CPU,
RAM, одного Gradle worker и одного тяжёлого этапа. Ошибку/OOM нужно разобрать;
не удаляйте lock/receipt и не запускайте тяжёлые сборки параллельно.

При `FOTO_PUB_OFFLINE=1` этап использует проверенный локальный Pub-кеш:
`flutter pub get --offline --enforce-lockfile` и
`flutter build apk --release`. Не добавляйте `--no-pub`: release plugin registrant
должен пересоздаваться без integration_test. CI создаёт debug APK с другим package ID и неподписанный release APK;
ни один из них не является подписанным обновлением Samsung. Если в кеше нет
закреплённой зависимости, этап останавливается: не меняйте lockfile и не
отключайте регистрацию плагинов. Команды можно запустить локально на HP, без SSH.

Проверка результата обязательна:

- Package ID: **de.opennoodle.gallery**.
- `versionName=5.7.3`, **versionCode=24**.
- SHA-256 сертификата подписанта:
  **ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18**.
- Сверьте сертификат с сохранённым подписанным APK Build 23. Запишите SHA исходного
  коммита, APK SHA-256, сертификат и версии toolchain в приватную квитанцию сборки.

При несовпадении любого пункта APK не устанавливать. Исправление сборки не должно
затрагивать установленное приложение или пользовательские данные.

## Установка без USB и ADB

Передайте проверенный `app-release.apk` на Samsung обычным способом и откройте
его в приложении «Мои файлы». Системный установщик должен предложить **обновить
существующее FOTO**. Установите обновление поверх Build 23 и откройте FOTO.
Не удаляйте приложение, не очищайте его данные, не сбрасывайте SQLite.

При экране «Требуется восстановление FOTO» нажмите «Восстановить и открыть FOTO»
один раз и дождитесь завершения. В успешном сценарии откроется существующая
галерея, а сохранённые очереди продолжат обычную синхронизацию. Дополнительный
логин, извлечение SQLite и подключение ADB не требуются.

При отказе исходные данные остаются внутри приложения. Нажмите «Экспортировать
резервную копию» и выберите локальную папку через системный диалог. Сохраните ZIP
у себя; он содержит приватную базу и отчёт. Поведение и причины безопасного отказа
подробно описаны в [отчёте о сохранности](../../specs/2026-10-31-foto-build24-sqlite-recovery-design.md).

Android обычно не допускает установку Build 23 поверх Build 24. Для исправления
проблем обновления нужен следующий versionCode с тем же сертификатом, с сохранением
данных. Не используйте переустановку или ручную подмену указателя активной базы.

## Если точное восстановление отказало

Экран показывает причину и технический код. Пустой WAL в режиме WAL не доказывает
полноту последних транзакций. Даже совпавший старый снимок и сохранённый SHM
не подтверждают отсутствие более позднего потерянного WAL:
`checkpoint_history_not_terminal` означает именно это ограничение.
Исходная база остаётся выбранной,
локальная синхронизация заблокирована. «Серверные фотографии» даёт отдельный
просмотр без локальных записей, если сессию удаётся подтвердить.

Для возвращения в полноценное FOTO нажмите **«Начать заново с серверными
фотографиями»**. Сохраните `FOTO-before-new-start.zip` через системный диалог
в «Загрузки» или другую локальную папку. Дождитесь повторного чтения и проверки
архива. Только после успешного сохранения появятся предупреждение и флажок
согласия на утрату несинхронизированных изменений в новой библиотеке.

Подтверждение создаёт новую локальную базу, сохраняя исходную и все снимки.
Подтверждённый аккаунт откроется автоматически; при непроверенной/истёкшей
сессии будет предложен обычный вход. FOTO заново скачает серверную библиотеку,
не исполняя старые удаления или загрузки. Фотографии на HP/Synology не удаляются.
При обрыве сети повторное открытие продолжает загрузку новой библиотеки.

Резервное копирование и управление файлами телефона изначально выключены.
Дождитесь загрузки, проверьте фотографии и альбомы, затем при необходимости
включите копирование отдельно и выберите альбомы. Исходный ZIP содержит личные
данные и токены: храните его у себя, не публикуйте в GitHub и не отправляйте
сторонним сервисам. Отмена экспорта/согласия или ошибка проверки сохраняют
старую базу; для новой попытки после завершения процесса потребуется новый экспорт.

## Проверка Shizuku и системного выбора фотографий

После успешного открытия галереи запустите Shizuku, включите Cloud Media Provider
в FOTO и выберите FOTO в системных настройках Photo Picker. Откройте системный
выбор фотографий, затем остановите и снова откройте FOTO. Проверьте тот же аккаунт,
галерею и состояние резервного копирования. Активация Shizuku не должна выбирать
другую локальную базу или запускать восстановление.

Если экран восстановления появляется повторно, сохраните технический код и новый
диагностический ZIP. `persisted_recovery_block` означает сохранённую блокировку;
сам по себе он не доказывает новое повреждение. `cloud_reader_sqlite_failure`
указывает на ошибку SQLite при чтении через проверенный Flutter-пул. Временная
недоступность native reader отражается отдельно и не сбрасывает базу. Не очищайте
данные и не удаляйте приложение. ZIP содержит приватные данные: передавать его
публично нельзя; для первичного разбора достаточно обезличенного отчёта.
