# FOTO Build 38: команды HP, Samsung и SideStore

Исходный код кандидата: **`e2cc9c001d3f8efd7f1762037e16932c56699d2c`**. Приложение в исходниках — `5.7.3+38`, package/Bundle ID — `de.opennoodle.gallery`. Подписанный Android APK собирается на HP с новым versionCode поверх установленного Build 38. Исходный `/home/doctoriceadm/FOTO-Build38.apk`, прежний ключ, кеши и модель сохраняются. Cloud эти команды на HP не выполнял: **HP_REQUIRED / DEVICE_REQUIRED**.

Все команды ниже выполняются владельцем на указанной машине. Не соединять staging Compose с production Compose; не останавливать существующие сервисы; не делать `reset --hard`, `clean`, uninstall или очистку данных приложения. При несовпадении SHA, подписи или грязном checkout остановиться и сохранить изменения. Production rollout требует отдельного решения после приёмки.

## 1. Зафиксировать исходники и отдельный каталог результатов на HP

Используется существующий checkout из MASTER, без второго клона, переноса caches или Docker root. Нужны Git, Python 3.11+, mise, GitHub CLI, Docker Compose v2 и существующий Android SDK 36 / Build Tools 36.0.0 / adb. Java 21 и Flutter 3.47.2 берутся из `mobile/mise.toml`.

```bash
set -euo pipefail
umask 077
export FOTO_SOURCE_SHA=e2cc9c001d3f8efd7f1762037e16932c56699d2c
export FOTO_REPO=/mnt/hp-data/foto-build38/source
cd "$FOTO_REPO"
test -z "$(git status --porcelain)"
git fetch origin codex/foto-build38-unified-16
FOTO_HANDOFF_SHA=$(git rev-parse origin/codex/foto-build38-unified-16)
git merge-base --is-ancestor "$FOTO_SOURCE_SHA" "$FOTO_HANDOFF_SHA"
export FOTO_EVIDENCE=$(mktemp -d /mnt/hp-data/foto-build38/acceptance-e2cc9c001d3f-XXXXXX)
git archive "$FOTO_HANDOFF_SHA" docs/acceptance specs/testing/foto-build38 mobile/test/pages/edit/goldens |
  tar -x -C "$FOTO_EVIDENCE"
export FOTO_ACCEPTANCE="$FOTO_EVIDENCE/docs/acceptance"
export FOTO_BRANCH=foto-build38-hp-e2cc9c001d3f
if git show-ref --verify --quiet "refs/heads/$FOTO_BRANCH"; then
  test "$(git rev-parse "$FOTO_BRANCH")" = "$FOTO_SOURCE_SHA"
  git switch "$FOTO_BRANCH"
else
  git switch -c "$FOTO_BRANCH" "$FOTO_SOURCE_SHA"
fi
test "$(git rev-parse HEAD)" = "$FOTO_SOURCE_SHA"
cp "$FOTO_ACCEPTANCE/build38-result-template.json" "$FOTO_EVIDENCE/result.json"
cd mobile
mise install
eval "$(mise env -s bash)"
cd "$FOTO_REPO"
flutter --version
java -version
command -v adb
# Используйте уже существующий SDK; не создавайте второй каталог SDK.
: "${ANDROID_HOME:?Укажите существующий Android SDK}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
df -h "$FOTO_REPO" /var/lib/docker
free -h
```

`FOTO_EVIDENCE` — приватный каталог. Не загружать необработанные логи, профили подписи, токены, APK/IPA и реальные фото в Git. В Git передаются обезличенный результат и SHA-256 доказательств; большие артефакты — отдельно.

Исполняемый вход в существующие проверенные builders: `bash "$FOTO_ACCEPTANCE/foto-hp-check.sh" preflight`, `mobile-tests`, `build-release`, `backend-tests`. Он не устанавливает APK и не обращается к production; проверяет чистоту checkout/SHA/ветку, создаёт отдельные приватные логи и сохраняет exit code. Для первых/третьих команд предварительно определить `FOTO_INSTALLED`/`FOTO_BUILD` из раздела 2; для backend — `export FOTO_BACKEND_ARTIFACT="$FOTO_EVIDENCE/backend"` после загрузки образа. Повторная сборка использует только уже проверенный immutable артефакт. Ниже приведены те же базовые команды с отдельными этапами для диагностики.

## 2. Подписанный APK и установка поверх Build 38

Подключить только выбранный Samsung по adb. Прежний ключ `mobile/android/key.jks` и `key.properties` должны уже существовать; их содержимое не выводить, не заменять и не генерировать. Ожидаемый SHA-256 сертификата: `ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.

```bash
adb devices -l
export FOTO_SERIAL='ВПИШИТЕ_СЕРИЙНЫЙ_НОМЕР_ИЗ_ADB'
adb -s "$FOTO_SERIAL" get-state
export FOTO_INSTALLED=$(adb -s "$FOTO_SERIAL" shell dumpsys package de.opennoodle.gallery |
  python3 -c 'import re,sys; s=sys.stdin.read(); m=re.search(r"versionCode=(\d+)",s); assert m,"Установленное FOTO не найдено"; print(m[1])')
export FOTO_BUILD=$(python3 -c 'import os; n=int(os.environ["FOTO_INSTALLED"]); assert n>=38; print(max(39,n+1))')
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --verbose --print-certs \
  /home/doctoriceadm/FOTO-Build38.apk > "$FOTO_EVIDENCE/baseline-signature.txt"
python3 - "$FOTO_EVIDENCE/baseline-signature.txt" <<'PY'
import re,sys
from pathlib import Path
s=Path(sys.argv[1]).read_text()
a=re.findall(r'Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F:]+)',s)
assert len(a)==1 and a[0].lower().replace(':','')=='ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18'
PY
python3 scripts/release/android_release.py preflight \
  --expected-head "$FOTO_SOURCE_SHA" --expected-branch "$FOTO_BRANCH" \
  --installed-build-number "$FOTO_INSTALLED" --build-number "$FOTO_BUILD"
python3 scripts/release/android_release.py build \
  --expected-head "$FOTO_SOURCE_SHA" --expected-branch "$FOTO_BRANCH" \
  --installed-build-number "$FOTO_INSTALLED" --build-number "$FOTO_BUILD" \
  > "$FOTO_EVIDENCE/android-build.log" 2>&1
python3 scripts/release/android_release.py postflight \
  --expected-head "$FOTO_SOURCE_SHA" --expected-branch "$FOTO_BRANCH" \
  --installed-build-number "$FOTO_INSTALLED" --build-number "$FOTO_BUILD" \
  > "$FOTO_EVIDENCE/android-postflight.log" 2>&1
export FOTO_APK="$FOTO_REPO/mobile/build/release-handoff/android-5.7.3-$FOTO_BUILD-e2cc9c001d3f/Foto.apk"
sha256sum "$FOTO_APK" > "$FOTO_EVIDENCE/android-apk.sha256"
adb -s "$FOTO_SERIAL" install -r "$FOTO_APK" > "$FOTO_EVIDENCE/android-install.log" 2>&1
adb -s "$FOTO_SERIAL" shell dumpsys package de.opennoodle.gallery > "$FOTO_EVIDENCE/android-installed.txt"
```

Builder действительно выполняет locked codegen, форматирование, analyzer, Flutter tests, native Android tests, новую universal release сборку и проверку package/version/сертификата/ABI/хеша. При повторном запуске он может переиспользовать уже проверенный артефакт и явно сообщает это. Его существующий manifest — доказательство сборки, а не проверки Samsung. Не использовать старый `sign-existing` профиль Build 8.

После установки вручную проверить сохранность аккаунта, локального каталога, настроек, альбомов и резервирования. `INSTALL_FAILED_UPDATE_INCOMPATIBLE` не обходить удалением старого приложения. На отдельном эмуляторе, не на пользовательском профиле телефона, можно дополнительно выполнить `flutter test integration_test/timeline_native_motion_test.dart -d ID_ЭМУЛЯТОРА` — это настоящий native-player тест, но не приёмка подписанного APK.

## 3. Docker backend: получить и проверить кандидат

Artifact-only run для этого SHA: **41992135140**. Использовать его только при `conclusion=success`. Если run неуспешен, не принимать сохранённый `unaccepted` артефакт.

```bash
cd "$FOTO_REPO"
gh run view 41992135140 --repo docice545/gallery --json headSha,conclusion |
  python3 -c 'import json,os,sys; r=json.load(sys.stdin); assert r["conclusion"]=="success" and r["headSha"]==os.environ["FOTO_SOURCE_SHA"]'
gh run download 41992135140 --repo docice545/gallery \
  -n gallery-trash-server-linux-amd64 -D "$FOTO_EVIDENCE/backend"
python3 - "$FOTO_EVIDENCE/backend" <<'PY'
import hashlib,json,os,sys
from pathlib import Path
p=Path(sys.argv[1]); m=json.loads((p/'manifest.json').read_text())
assert m['sourceCommit']==os.environ['FOTO_SOURCE_SHA']
assert m['isolatedSmoke'].startswith('PASS:')
with (p/'gallery-server-linux-amd64.tar.gz').open('rb') as f:
    assert hashlib.file_digest(f,'sha256').hexdigest()==m['archiveSHA256']
PY
docker --host=unix:///var/run/docker.sock load -i "$FOTO_EVIDENCE/backend/gallery-server-linux-amd64.tar.gz"
python3 scripts/release/server_artifact_smoke.py --local-disposable-lab \
  "$FOTO_SOURCE_SHA" "$FOTO_EVIDENCE/backend" > "$FOTO_EVIDENCE/backend-http.log" 2>&1
```

Этот runner создаёт только свежие собственные PostgreSQL/Redis/API/microservices контейнеры и синтетические файлы, проверяет настоящий HTTP upload/Trash/Restore/thumbnail/HEAD/permanent-delete/внешнюю тестовую библиотеку, затем удаляет только созданные им контейнеры и тома. Он не принимает production URL или пути пользовательских данных. Не устанавливать `GITHUB_ACTIONS=true` на HP. Для локального теста предусмотрен явный флаг выше.

При необходимости собрать backend на HP вместо скачивания: `MIGRATION_BASE_SHA=0c8be542121d415f4d748dda20367044cd200d40 scripts/release/server_build.sh "$FOTO_SOURCE_SHA" "$FOTO_EVIDENCE/backend-built-on-hp"`. Нужны jq/ImageMagick, сеть для закреплённых зависимостей и достаточный Docker disk budget; сборка не публикует образ и не запускает production. После неё выполнить тот же isolated smoke с новым каталогом.

## 4. Отдельный staging для APK/iOS и настоящего AI-ластика

Использовать только синтетические/специально выделенные тестовые фотографии. Не монтировать production media, NAS, PostgreSQL или Redis. У файла модели только read-only bind; остальные volumes новые и принадлежат уникальному Compose project. Порт только `127.0.0.1:22938`. API подключён к отдельному bridge для публикации loopback-порта; DB/Redis/worker остаются в internal network. В internal-only сети Docker не публиковал порт — это проверено и исправлено. Полный совместный запуск четырёх сервисов в Cloud упёрся в disk budget драйвера `vfs`; отдельно настоящий backend HTTP и worker inference прошли, а новая топология проверена лёгкой синтетической TCP fixture. Совместный HP smoke не заменён этими результатами. Перед запуском проверить `docker info --format '{{.Driver}}'` и свободное место: для `vfs` нужны десятки GiB дополнительного запаса; не очищать чужие образы или переносить Docker root. Резервируйте RAM для дополнительного backend и 3 GiB sidecar; если ресурсов недостаточно, не запускайте staging одновременно с существующей нагрузкой.

```bash
export FOTO_MODEL_FILE=/mnt/hp-data/gallery-inpainting/models/big-lama.pt
python3 - <<'PY'
import hashlib,os
from pathlib import Path
with Path(os.environ['FOTO_MODEL_FILE']).open('rb') as f:
    assert hashlib.file_digest(f,'sha256').hexdigest()=='344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9'
PY
export FOTO_INPAINT_IMAGE=foto-inpainting:build38-e2cc9c001d3f
export FOTO_CA_FILE=${FOTO_CA_FILE:-/etc/ssl/certs/ca-certificates.crt}
test -s "$FOTO_CA_FILE"
DOCKER_BUILDKIT=1 docker --host=unix:///var/run/docker.sock build \
  --secret "id=proxy_ca,src=$FOTO_CA_FILE" \
  --build-arg HTTP_PROXY --build-arg HTTPS_PROXY --build-arg NO_PROXY \
  -t "$FOTO_INPAINT_IMAGE" "$FOTO_REPO/inpainting"
# Изолированная проверка настоящего worker до подключения staging API.
export FOTO_INPAINT_ID=$(docker --host=unix:///var/run/docker.sock image inspect --format '{{.Id}}' "$FOTO_INPAINT_IMAGE")
python3 "$FOTO_ACCEPTANCE/inpainting-docker-check.py" --image "$FOTO_INPAINT_ID" \
  --model "$FOTO_MODEL_FILE" --output "$FOTO_EVIDENCE/inpainting-http-$(date -u +%Y%m%dT%H%M%SZ)"
python3 - <<'PY'
import json,os,secrets
from pathlib import Path
p=Path(os.environ['FOTO_EVIDENCE']); m=json.loads((p/'backend/manifest.json').read_text())
values={'FOTO_SOURCE_SHA':os.environ['FOTO_SOURCE_SHA'],'FOTO_SERVER_IMAGE':m['imageId'],
 'FOTO_INPAINT_IMAGE':os.environ['FOTO_INPAINT_ID'],'FOTO_MODEL_FILE':os.environ['FOTO_MODEL_FILE'],
 'FOTO_LAB_PASSWORD':secrets.token_hex(24),'FOTO_INPAINT_TOKEN':secrets.token_hex(32)}
with (p/'staging.env').open('x') as f:
    for k,v in values.items(): f.write(k+'='+v+'\n')
(p/'staging.env').chmod(0o600)
PY
export FOTO_PROJECT=$(python3 -c 'import uuid; print("foto-build38-e2cc9c001d3f-"+uuid.uuid4().hex[:12])')
printf '%s\n' "$FOTO_PROJECT" > "$FOTO_EVIDENCE/staging-project.txt"
# Первый запуск: не присоединяться к уже существующему проекту с тем же именем.
test -z "$(docker --host=unix:///var/run/docker.sock ps -aq --filter label=com.docker.compose.project="$FOTO_PROJECT")"
docker --host=unix:///var/run/docker.sock compose -p "$FOTO_PROJECT" \
  --env-file "$FOTO_EVIDENCE/staging.env" -f "$FOTO_ACCEPTANCE/build38-staging.compose.yml" config --quiet
docker --host=unix:///var/run/docker.sock compose -p "$FOTO_PROJECT" \
  --env-file "$FOTO_EVIDENCE/staging.env" -f "$FOTO_ACCEPTANCE/build38-staging.compose.yml" up -d
curl --fail --retry 30 --retry-delay 2 --retry-connrefused http://127.0.0.1:22938/api/server/ping
adb -s "$FOTO_SERIAL" reverse tcp:22938 tcp:22938
```

Подождать готовности API; временная ошибка `curl` до завершения миграций не считается PASS. Samsung через USB использует `http://127.0.0.1:22938`, отдельного staging-пользователя и тестовые данные. Перед выходом из обычного аккаунта дождаться завершения его upload/backup и записать исходные настройки. На iPhone staging можно открыть через существующий доверенный туннель: не изменять VPN/DNS/роутер и не открывать порт в Интернет ради теста.

Проверить реальные результаты ластика: замкнутая маска, кисть, Undo, до/после, отмена, ошибка worker, сохранение новой копии при неизменном оригинале. Сцены: собака на траве, человек у воды, предмет/тень, кирпич/повторяющаяся текстура. Облачные синтетические результаты удаляют объекты, но имеют ограничения восстановления мелкой травы и кладки; это не фотореалистическая приёмка. Записать фактическую задержку/RSS на HP. В каждом staging sidecar оставлять один процесс worker; не масштабировать его и не скачивать модель повторно. Существующий production worker не изменять.

Остановка только своего staging, с сохранением volumes для разбора:

```bash
docker --host=unix:///var/run/docker.sock compose -p "$FOTO_PROJECT" \
  --env-file "$FOTO_EVIDENCE/staging.env" -f "$FOTO_ACCEPTANCE/build38-staging.compose.yml" logs --no-color \
  > "$FOTO_EVIDENCE/staging-private.log"
docker --host=unix:///var/run/docker.sock compose -p "$FOTO_PROJECT" \
  --env-file "$FOTO_EVIDENCE/staging.env" -f "$FOTO_ACCEPTANCE/build38-staging.compose.yml" down
adb -s "$FOTO_SERIAL" reverse --remove tcp:22938
```

Этот тест не подтверждает production backup/restore, NAS permissions или rollback. Их проверять на отдельном восстановленном снимке, не на действующей БД. Не запускать старые HP release/deletion scripts с production-конфигурацией как часть этой инструкции.

## 5. iOS: macOS/Xcode → SideStore → устройство

Готового подписанного IPA пока нет: **SIGNING_REQUIRED**. macOS runner доступен; текущая build-only сборка **41992130730** использует тот же source SHA. Она компилирует Runner и оба расширения и сохраняет **Photos-unsigned.ipa**. Это настоящий неподписанный IPA, а не готовый устанавливаемый релиз. GitHub API списка signing secrets вернул 403; доступного подтверждённого Personal Team/provisioning profile и iPhone в Cloud нет.

Скачивание после успешного run (из чистого checkout кандидата):

```bash
python3 mobile/scripts/release/ios_unsigned.py fetch --run 41992130730 \
  --expected-commit "$FOTO_SOURCE_SHA" --expected-branch codex/foto-build38-unified-16 \
  --version 5.7.3 --build 38 --output "$FOTO_EVIDENCE/ios"
```

Для воспроизводимой локальной сборки на **macOS с Xcode 26**, в выделенном чистом checkout этого SHA: установить mise-pins, Ruby/Bundler из `mobile/ios`, jq/coreutils/gnu-sed/ImageMagick, применить существующий branding overlay с `FORK_VERSION=5.7.3 BUILD_NUMBER=38`, выполнить:

```bash
# macOS; только выделенный build checkout, не HP checkout с Android ключом.
: "${FOTO_MAC_REPO:?Укажите существующий macOS build checkout}"
cd "$FOTO_MAC_REPO"
test "$(git rev-parse HEAD)" = e2cc9c001d3f8efd7f1762037e16932c56699d2c
test -z "$(git status --porcelain)"
brew install mise jq coreutils gnu-sed imagemagick ruby@3.3
export PATH="$(brew --prefix ruby@3.3)/bin:$(brew --prefix gnu-sed)/libexec/gnubin:$(brew --prefix coreutils)/libexec/gnubin:$PATH"
gem install bundler
(cd mobile/ios && bundle install)
export FORK_VERSION=5.7.3 BUILD_NUMBER=38
./branding/scripts/apply-branding.sh
./branding/scripts/verify-branding.sh
cd mobile
mise install
bash scripts/ios_build_only.sh
test -s build/ios/ipa/Photos-unsigned.ipa
cd ..
```

Скрипт закрепляет Flutter 3.47.2, выполняет codegen и `pod install --deployment`, собирает archive `--no-codesign`, проверяет реальные bundle metadata/icons и выпускает unsigned IPA. Не обновлять Podfile.lock автоматически ради зелёной сборки. Runner: iOS 15+, ShareExtension: 16+, Widget: 17+; совместимость расширений на более старой системе проверить отдельно.

Подготовка SideStore на Mac, с **реальным** Personal Team ID и фактическим хешем входного IPA:

```bash
export FOTO_PERSONAL_TEAM='РЕАЛЬНЫЙ_TEAM_ID'
export FOTO_UNSIGNED_IPA='/полный/путь/Photos-unsigned.ipa'
export FOTO_IPA_SHA=$(shasum -a 256 "$FOTO_UNSIGNED_IPA" | cut -d ' ' -f 1)
python3 mobile/scripts/release/prepare_sidestore.py \
  --ipa "$FOTO_UNSIGNED_IPA" --input-sha256 "$FOTO_IPA_SHA" \
  --team-id "$FOTO_PERSONAL_TEAM" --version 5.7.3 --build 38 \
  --output /приватный/каталог/Foto-SideStore-seed.ipa
```

Seed получает только ad-hoc подпись и **всё ещё не является готовым устанавливаемым IPA**. SideStore должен создать корректные Apple provisioning/signatures для выбранного устройства, приложения и расширений. Общий App Group и custom `AppGroupId` должны совпадать после Team mapping; исходные Apple-associated-domains/Wi-Fi entitlements не выдавать за доступные Personal Team. Проверить фактические entitlements, профиль/expiry, re-sign/refresh, запуск, Share Extension/Widget и общий контейнер. Бесплатные лимиты Apple/число приложений и срок обновления определяются текущим аккаунтом и SideStore; вечная подпись не обещается.

Приёмка iOS: установка, повторный запуск после offline cold start, limited/full PhotoKit permissions, серверный/local Apple Live Photo, download/save/share fidelity, backend sync, foreground/background upload и cancellation, редактор, AI-ластик, обе настройки анимации и Reduce Motion. Android embedded Motion Photo не считать Apple Live Photo только потому, что сохранился still. В `result.json` записать хеш **фактически подписанного и установленного** IPA, Team ID, срок профиля и доказательства установки. Если SideStore не позволяет экспорт подписанного файла, обозначить ограничение и не называть seed готовым IPA.

## 6. Фактическая приёмка Samsung и результат

Пройти все строки MASTER и V01–V12 из соседних матриц. Обязательно: холодный offline старт; online → offline → online; немедленный fast-scroll по годам до окончания декодирования; верная дата; отсутствие пустот/дублей воспоминаний; сохранение anchor; отдельные 4:3/16:9/панорамы в обоих режимах; одиночное/групповое удаление с отказом/разрешением/частичным результатом; реальная проверка MediaStore; Undo; переключатель эффекта после restart; reduced motion; haptics; Live/Motion Photo; backup; Free Space только после подтверждённых серверных копий; редактор без сдвига viewport.

Для 60/120 Hz записать реальные видео и frame timings (Perfetto/Android Studio Profiler либо доступная device frame statistics), число кадров, длительность, dropped/janky frames и условия. Не переносить время Flutter widget pumps в показатель FPS. Снимки и видео должны содержать только тестовые фотографии.

`result.json` — машинно-читаемый шаблон. До теста оставлять `HP_REQUIRED`, `DEVICE_REQUIRED`, `SIGNING_REQUIRED`; каждый PASS снабжать `testedAt`, моделью/ОС, artifact SHA и `evidence: [{"path":"относительный-путь","sha256":"64 hex"}]`. FAIL должен содержать воспроизведение и фактический лог. `finalAccepted` остаётся false, пока Android APK, подписанный iOS IPA, backend и все обязательные аппаратные сценарии не подтверждены. Коммиты и облачные скриншоты не заменяют эти доказательства.
