# FOTO Android Release Preflight — исправленный отчёт

## Подтверждённое состояние HP

Данные предоставлены пользователем непосредственно с HP и приняты как подтверждённые:

- Checkout `/mnt/hp-data/foto-build38/source` **существует**.
- Ветка `foto-build39-hp-serial-tests`, HEAD `54f335e2a28af2de6d485f5a53acb05934837324`, рабочее дерево чистое на момент проверки HP.
- `/home/doctoriceadm/FOTO-Build39.apk` **существует**, сообщённый размер около 185 MB.
- `mobile/android/key.properties` и `mobile/android/key.jks` **существуют**, это сохраняемые оригиналы.
- GitHub Hotfix: `fc1126dd4a283d7ab803c237d45914b3d60b5568`, ветка `codex/foto-build38-unified-16`.

Отсутствие HP checkout/keystore удалено из причин блокировки. GitHub HTTP 422 и отсутствие объекта в Cloud **не опровергают существование локального HP-коммита**. Проверка `git ls-remote origin refs/heads/foto-build39-hp-serial-tests` не нашла этой ветки среди объявленных GitHub refs. Это ещё не устанавливает происхождение самого коммита: нужны его родители, reflog и HP-only изменения.

## Реальные оставшиеся вопросы

| Проверка | Состояние |
| --- | --- |
| Происхождение 54f335e2 и сохранение HP-only исправлений | Нужен результат `history`. Нельзя автоматически подменять HP-код Hotfix-кодом до просмотра локальных изменений |
| SDK build-tools | Отсутствие команд в PATH не является отсутствием SDK. `sdk` ищет готовые инструменты и возвращает абсолютные пути; ничего не устанавливает |
| Идентичность APK/ключа | Нужны фактические packageName, versionCode и certificateSHA256 Build 39, совпадение с настроенным PrivateKeyEntry в key.jks |
| Установленный Samsung | Нужны фактический versionCode, package/certificate и сравнение установленного base.apk с сохранённым Build39 APK |
| Google Lens | Поиск текущего изображения в одно нажатие **ещё не реализован и не подтверждён**. Диалог → Sharesheet не считается его выполнением |

Наличие исходного ключа подтверждено; способность выполнить будущую подпись здесь не выдаётся за проверенную подпись. Нового APK пока нет по прямому запрету на сборку.

## Команды preflight на HP

Архив `FOTO-Android-Preflight.zip` содержит этот файл, `android-preflight.py`, сценарий отдельного worktree и контрольные суммы. Это пакет команд, не приложение. Скопировать архив на HP, задать реальный путь к нему и распаковать в новый приватный каталог:

```bash
set -euo pipefail
umask 077
: "${FOTO_PREFLIGHT_ZIP:?Укажите путь к скачанному FOTO-Android-Preflight.zip}"
export FOTO_CHECK=$(mktemp -d /mnt/hp-data/foto-build38/android-preflight-XXXXXX)
python3 -m zipfile -e "$FOTO_PREFLIGHT_ZIP" "$FOTO_CHECK"
cd "$FOTO_CHECK"
sha256sum -c SHA256SUMS
```

Получить объекты Hotfix, не переключая локальную ветку и не меняя файлы HP. Эта команда не публикует локальный коммит:

```bash
git -C /mnt/hp-data/foto-build38/source \
  -c core.hooksPath=/dev/null -c maintenance.auto=false \
  fetch --no-tags origin refs/heads/codex/foto-build38-unified-16
python3 android-preflight.py history > history.json
```

`history.json` содержит текущие HEAD/ветку/status, родителей/сообщения 54f335e2 и fc1126dd4, изменённые пути, локальный reflog, общий предок, HP-only коммиты, изменения mobile/release tooling и эквивалентность патчей. Сам скрипт ничего не fetch/push/checkout/merge/reset. Если HP-only изменения содержат нужные runtime/native/signing/test fixes, сначала сопоставить их с Hotfix. Они остаются в исходном checkout; автоматически отбрасывать или переносить их нельзя.

Найти инструменты и проверить APK:

```bash
python3 android-preflight.py sdk > sdk.json
python3 android-preflight.py apk > build39.json
python3 android-preflight.py keys > keys.json
```

Поиск SDK использует `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `mobile/android/local.properties` и обычные Linux-каталоги. Предпочтение — Build Tools 36.0.0; другая установленная стабильная версия может использоваться для чтения APK. Возвращаются `aapt`, `apksigner`, `adb` по абсолютным путям, а также отдельные флаги наличия SDK 36/Build Tools 36.0.0 для будущего release helper.

Для нестандартного SDK явно указать **существующий** каталог во всех командах:

```bash
: "${FOTO_ANDROID_SDK:?Полный путь к существующему SDK на HP}"
python3 android-preflight.py sdk --sdk "$FOTO_ANDROID_SDK" > sdk.json
python3 android-preflight.py apk --sdk "$FOTO_ANDROID_SDK" > build39.json
python3 android-preflight.py keys --sdk "$FOTO_ANDROID_SDK" > keys.json
```

`apk` запускает `aapt dump badging` и `apksigner verify --verbose --print-certs`, сохраняет packageName/versionName/versionCode/certificateSHA256/APK SHA-256. Ожидаемый packageName — `de.opennoodle.gallery`.

`keys` читает настроенный **alias**, проверяет ignored-файлы и через **keytool -list** сравнивает сертификат именно этого PrivateKeyEntry с Build39 APK. Содержимое key.properties не выводится. Пароль существующего keystore вводится один раз **локально в интерактивном HP-терминале без эха**; он передаётся keytool через приватный stdin pipe, не через argv/env/логи. В неинтерактивном режиме проверка останавливается. Подпись и создание ключей не выполняются; хеши исходных signing-файлов сверяются до/после без их вывода.

Исторический pin текущего release helper: `ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`. Он отмечается отдельным полем, а не подставляется вместо измеренного сертификата. Если реальные APK/key/Samsung совпадают между собой, но отличаются от этого pin, нужно выяснить расхождение в release metadata; заменять оригинальный ключ нельзя.

Проверить реальную установку Samsung, не устанавливая и не удаляя приложение:

```bash
export FOTO_ADB=$(python3 -c 'import json; print(json.load(open("sdk.json"))["adb"])')
"$FOTO_ADB" devices -l
: "${FOTO_SERIAL:?Укажите serial нужного Samsung из adb devices -l}"
python3 android-preflight.py device --serial "$FOTO_SERIAL" > samsung.json
# Если SDK нестандартный, добавить --sdk "$FOTO_ANDROID_SDK" к предыдущей команде.
```

`device` читает dumpsys/pm path, временно копирует установленный base.apk в собственный приватный каталог на SSD HP и проверяет его через те же инструменты. Только собственная временная копия затем удаляется. Содержимое телефона, оригинальные фото и ключи не меняются. Сертификаты установленного APK и сохранённого Build39 должны совпасть. Различие SHA-256 файлов фиксируется явно: наличие Build39.apk на диске не доказывает, что установлен именно этот файл.

Выбранный будущий versionCode записывается в `samsung.json`:
`max(versionCode сохранённого Build39, versionCode Samsung) + 1`.
Это технический счётчик обновления Build 39 Hotfix, а не начало нового Build 40.
Значение 39 не предполагается по имени файла. Параметр не изменяет pubspec или установленное приложение.

## Доставка Hotfix с сохранением production checkout

После просмотра `history.json` можно подготовить изолированную копию исходников:

```bash
cd "$FOTO_CHECK"
bash stage-hotfix-worktree.sh
```

Сценарий создаёт **новый уникальный detached worktree** вида
`/mnt/hp-data/foto-build38/hotfix-fc1126dd4-XXXXXX` на точном Hotfix SHA.
Объекты Git общие; нового клона и новой истории проекта нет. Существующая ветка
`foto-build39-hp-serial-tests` остаётся на 54f335e2. Новая локальная ветка не создаётся.
Состояние staged/unstaged/untracked фиксируется до/после, ничего не stash/reset/clean.
Ключи не копируются и не генерируются; в новой копии их нет. Checkout hooks для этой
операции отключены, чтобы доставка исходников не запускала пользовательские hooks.
Сборка, подпись и установка отсутствуют.

Если обнаружено изменение исходного HEAD/ветки относительно подтверждённых данных,
проверка останавливается. Если после операции состояние рабочего дерева изменилось,
результат требует просмотра; сценарий не удаляет ни чужие изменения, ни созданную копию.

Файловая доставка безопасна для исходного checkout, но сама по себе не подтверждает,
что все HP-only исправления включены в Hotfix. Это отдельный пункт анализа истории.

## Последующий план обновления — не выполнять в этом preflight

1. Закрыть расхождения `history.json`, `build39.json`, `keys.json`, `samsung.json`.
2. После отдельного поручения на сборку использовать **кандидатную копию**. Текущий
   `android_release.py` требует именованную ветку; detached worktree сейчас предназначен
   для проверки. Для будущей сборки нужна отдельная кандидатная ветка только в новой
   копии, без переключения production checkout. Старые команды build против HP checkout
   с требованием HEAD=fc1126 больше не применяются.
3. Сохранить оригиналы подписи на HP. При подготовке разрешённой сборки использовать
   их через проверенные локальные пути/ссылки в кандидате, без копирования в Git/Cloud
   и без создания нового ключа. Повторно проверить alias/сертификат.
4. Для будущего APK передать рассчитанный новый versionCode, сохранить packageName,
   выполнить предусмотренные analyze/Flutter/native tests и postflight артефакта.
   Перед установкой проверить package/certificate и что code больше актуального
   Samsung code; если устройство обновилось после preflight, перечитать его состояние.
5. Только после разрешения установки применить `adb -s "$FOTO_SERIAL" install -r "$FOTO_APK"`.
   Не использовать uninstall, clear-data, downgrade `-d` или замену ключа при ошибке.
   Проверить сохранность аккаунта, альбомов, настроек, локального каталога и backup.

`build-after-authorization.sh` из прежнего отчёта теперь намеренно останавливается:
он не должен менять локальный production SHA или выполнять сборку в этом задании.

## Фактическая проверка подготовленных команд

**9 PASS** в [preflight-tools-tests.log](preflight-tools-tests.log): обнаружение SDK
по абсолютным путям/пробелам, отсутствие pair инструментов, разбор APK и отклонение
другого package, совпадение/несовпадение сертификата без передачи пароля в argv/env,
настоящий временный Git worktree со staged/unstaged/untracked/ignored-key fixtures.
Последний тест подтвердил сохранность исходной ветки/HEAD/данных и отсутствие запуска
checkout hook. Дополнительно выполнен `bash -n` сценариев.

Это проверки инструментов на синтетических данных, **не PASS измерений на HP/Samsung**.
Реальные сертификаты, версия Samsung и происхождение HP SHA ещё ожидают выводов
подготовленных команд. Google Lens в одно нажатие остаётся незавершённым.

## Повторная попытка 2026-11-05

[preflight-attempt.json](preflight-attempt.json) фиксирует текущие фактические проверки Cloud.
Подключение к HP не настроено: SSH/VPN/credentials отсутствуют, Samsung через ADB
не подключён. Это не означает отсутствия подтверждённых пользователем файлов HP.
Пять HP JSON ещё не получены; worktree на HP не создан. Исходники и существующий
индекс Git сохранены. [GOOGLE-LENS-PLAN.md](GOOGLE-LENS-PLAN.md) содержит отдельный
план без изменения приложения. Одно нажатие остаётся NOT_IMPLEMENTED.
