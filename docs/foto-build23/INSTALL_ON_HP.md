# FOTO Build 23 — сборка на HP и обновление Samsung

Эта инструкция меняет только Android APK. Production backend Build 22 уже
работает как `5.7.3`; его пересборка, перезапуск и миграции не требуются.

Исходный SHA Build 22: `a316a23f92c798da8927c34d1146a1d2de91b05a`.
Новая ветка: `codex/foto-build23-sqlite-one-tap-recovery`. Используйте **итоговый
40-символьный SHA из поставки**, для которого успешно завершился workflow
`FOTO Build 23 SQLite recovery`.

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
foto_sha=${FOTO_RELEASE_SHA:?Укажите итоговый опубликованный SHA Build 23}
[[ "$foto_sha" =~ ^[0-9a-f]{40}$ ]]
cd "$foto_repo"
test -z "$(git status --porcelain)"
(
  flock -n 9
  git fetch origin refs/heads/codex/foto-build23-sqlite-one-tap-recovery:refs/remotes/origin/codex/foto-build23-sqlite-one-tap-recovery
  git cat-file -e "$foto_sha^{commit}"
  git merge-base --is-ancestor "$foto_sha" refs/remotes/origin/codex/foto-build23-sqlite-one-tap-recovery
  git switch --detach "$foto_sha"
) 9>"$foto_state/heavy-stage.lock"
test "$(git rev-parse HEAD)" = "$foto_sha"
rg '^version: 5\.7\.3\+23$' mobile/pubspec.yaml
flutter --version
"${JAVA_HOME:?Используйте установленный JDK}/bin/javac" -version
foto_runner="$foto_repo/tools/foto-automation/foto-stage-runner.py"
for foto_stage in openapi-dart flutter-dependencies flutter-codegen flutter-analyze; do
  python3 "$foto_runner" --repo "$foto_repo" --state "$foto_state" --resume "$foto_stage"
done
python3 "$foto_runner" --repo "$foto_repo" --state "$foto_state" --resume flutter-test \
  test/data/db test/pages/common/sqlite_recovery_page_test.dart \
  test/infrastructure/repositories/sqlite_sync_recovery_test.dart \
  test/infrastructure/repositories/sqlite_sync_recovery_file_test.dart \
  test/domain/utils/background_sync_test.dart
test -s mobile/android/key.properties
test -s mobile/android/key.jks
python3 "$foto_runner" --repo "$foto_repo" --state "$foto_state" --resume android-apk
foto_apk="$foto_repo/mobile/build/app/outputs/flutter-apk/app-release.apk"
test -s "$foto_apk"
apksigner verify --verbose --print-certs "$foto_apk"
aapt dump badging "$foto_apk"
sha256sum "$foto_apk"
git diff --exit-code -- mobile/pubspec.yaml mobile/pubspec.lock mobile/android/app/build.gradle
```

Если существующий ключ настроен по другому пути, проверяйте фактическую локальную
конфигурацию; не копируйте и не заменяйте ключ. Runner сохраняет ограничение CPU,
RAM, одного Gradle worker и одного тяжёлого этапа. Ошибку/OOM нужно разобрать;
не удаляйте lock/receipt и не запускайте тяжёлые сборки параллельно.

Финальный этап делает `flutter pub get --enforce-lockfile` и
`flutter build apk --release`. Не добавляйте `--no-pub`: release plugin registrant
должен пересоздаваться без integration_test. CI создаёт тестовый debug APK с
другим package ID; его нельзя использовать для обновления Samsung.

Проверка результата обязательна:

- Package ID: **de.opennoodle.gallery**.
- `versionName=5.7.3`, **versionCode=23**.
- SHA-256 сертификата подписанта:
  **ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18**.
- Сверьте сертификат с сохранённым подписанным APK Build 22. Запишите SHA исходного
  коммита, APK SHA-256, сертификат и версии toolchain в приватную квитанцию сборки.

При несовпадении любого пункта APK не устанавливать. Исправление сборки не должно
затрагивать установленное приложение или пользовательские данные.

## Установка без USB и ADB

Передайте проверенный `app-release.apk` на Samsung обычным способом и откройте
его в приложении «Мои файлы». Системный установщик должен предложить **обновить
существующее FOTO**. Установите обновление поверх Build 22 и откройте FOTO.
Не удаляйте приложение, не очищайте его данные, не сбрасывайте SQLite.

При экране «Требуется восстановление FOTO» нажмите «Восстановить и открыть FOTO»
один раз и дождитесь завершения. В успешном сценарии откроется существующая
галерея, а сохранённые очереди продолжат обычную синхронизацию. Дополнительный
логин, извлечение SQLite и подключение ADB не требуются.

При отказе исходные данные остаются внутри приложения. Нажмите «Экспортировать
резервную копию» и выберите локальную папку через системный диалог. Сохраните ZIP
у себя; он содержит приватную базу и отчёт. Поведение и причины безопасного отказа
подробно описаны в [отчёте о сохранности](SQLITE_RECOVERY.md).

Android обычно не допускает установку Build 22 поверх Build 23. Для исправления
проблем обновления нужен следующий versionCode с тем же сертификатом, с сохранением
данных. Не используйте переустановку или ручную подмену указателя активной базы.
