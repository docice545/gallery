# FOTO Build 17 — безопасная передача на HP

Статус: **BLOCKED для установки до проверки подписи действующим проектным ключом**.
Эта инструкция передаёт исходники и готовый unsigned APK. Она не разворачивает backend,
не запускает Codex, не меняет production, manifest, NAS или системные лимиты.

## 1. Получение исходников без изменения рабочего дерева HP

Выполните от `codex-gallery` в существующем репозитории. Не выполняйте reset/clean,
checkout поверх изменений, autostash или force-push. Сохранность локальных
`server/test/mappers.ts`, `.bak`, progress/pending-tasks и обоих manifest обязательна.

```bash
set -euo pipefail
umask 077
cd /mnt/hp-data/codex-work/foto-integration
git fetch --no-tags origin refs/heads/codex/foto-build17-web-handoff
git merge-base --is-ancestor 244ae32fc6dc1bf1199ea1bbd3c06a1e85e8948d FETCH_HEAD
test "$(git rev-parse 244ae32fc6dc1bf1199ea1bbd3c06a1e85e8948d^{commit})" = 244ae32fc6dc1bf1199ea1bbd3c06a1e85e8948d
TRANSFER=$(mktemp -d /mnt/hp-data/codex-work/foto-build17-cloud.XXXXXXXX)
git archive 244ae32fc6dc1bf1199ea1bbd3c06a1e85e8948d tools/foto-automation FOTO_BUILD17_HANDOFF.md \
  scripts/release/SignExistingApk.java \
  scripts/release/android_release.py scripts/release/android_sign_package.py \
  | tar -x -C "$TRANSFER"
printf 'SOURCE STAGED: %s\n' "$TRANSFER"
```

`git fetch` изменяет только Git refs/объекты; working tree и локальные checkpoints не меняются.
Извлекается только указанный source SHA, даже если ветка продвинулась. Другой SHA автоматически
не подставляется. Итоговые TEST_REPORT и эта инструкция скачиваются отдельно из release. Код приложения интегрируется после сравнения локальных изменений, отдельно от
установки инструментов. Облачный mapper исправлен независимо; локальный HP mapper не был получен.

Для установки runner после review и завершения старой сессии используйте
`tools/foto-automation/README.md` из staging. В нём указаны прежние HP пути, backup launcher,
права и проверка `--dry-run`. Не переносите Cloud state и не удаляйте lock-файлы.

## 2. Артефакт и проверка

- APK source: `244ae32fc6dc1bf1199ea1bbd3c06a1e85e8948d`.
- Package: `de.opennoodle.gallery`, versionName `5.7.3`, versionCode `17`.
- Файл: `Foto-5.7.3-build17-unsigned.apk`.
- SHA-256: `49e2ee65a8dd881085edf2934b72cf19985f28ee9918de37ce99eb1cd70efd08`.
- Размер: `188090091` bytes.
- Состояние подписи: **UNSIGNED**, не debug-signed; напрямую не устанавливать.
- GitHub draft-release (доступ владельцу репозитория после входа): https://github.com/docice545/gallery/releases/tag/untagged-d254aea7a1c2b4364657.

**Текущее состояние: assets отсутствуют.** Создание draft прошло, но загрузка файлов
получила HTTP401 Bad credentials на uploads.github.com. Доступ к metadata/API и git push
не подтверждает upload credential. Получение APK через GitHub пока **не проверено и недоступно**.
Комплект находится в Cloud `/workspace/foto-build17-release-244ae32fc6dc`; исходный APK указан в handoff.
Не вводите токены в чат; повторная загрузка требует действующей GitHub-аутентификации для uploads.

Следующий блок download применим **после появления assets**, сейчас он не сможет получить комплект.
Draft выбран намеренно: published release в этом репозитории запускает Docker/CLI/SDK workflows.
Для скачивания нужен GitHub-вход с доступом к draft; анонимная ссылка не поддерживается.

```bash
set -euo pipefail
umask 077
DOWNLOAD_DIR=$(mktemp -d "${PWD}/foto-build17-download.XXXXXXXX")
gh release download foto-5.7.3-build17-cloud-244ae32fc6dc \
  --repo docice545/gallery --dir "$DOWNLOAD_DIR"
(cd "$DOWNLOAD_DIR" && sha256sum -c SHA256SUMS)
printf 'VERIFIED DOWNLOAD: %s\n' "$DOWNLOAD_DIR"
```

Выполняйте от владельца существующей GitHub-аутентификации; ключ Android для скачивания не нужен.
После успешной загрузки assets скачайте APK и `SHA256SUMS` из указанного release в новый каталог. Выполните
`sha256sum -c SHA256SUMS` для всего скачанного комплекта или сравните APK с указанным
здесь SHA. Сверяйте полный hash, а не только имя. Не пересобирайте APK ради подписи.

## 3. Подпись существующим HP-ключом без Gradle и без новой пары ключей

Выполняет **существующий владелец signing key**, не Cloud. Укажите пять фактических путей:
полученный staging `TRANSFER`, скачанный `APK`, действующий `KEYDIR` с `key.jks` и
`key.properties`, `ANDROID_SDK_ROOT` с build-tools 36.0.0 и `JAVA_HOME` полного JDK.
Секреты не нужно вводить в чат, аргументы команд или переменные паролей.

Ключевые файлы должны уже принадлежать этому пользователю и иметь `0600`. Скрипт их не
создаёт и не меняет. Существующий Java helper требует alias `foto` и storeFile, указывающий
на тот же `KEYDIR/key.jks`. При несовпадении он откажет; не исправляйте alias/сертификат
наугад и не создавайте новый key. Старый `android_sign_package.py sign` предназначен
строго для Build 11; его профиль для Build 17 не подделывается. Ниже используются только
существующие проверки и Java helper, без изменения их контракта.

```bash
set -euo pipefail
umask 077
: "${TRANSFER:?Путь staging из раздела 1}"
: "${APK:?Полный путь скачанного unsigned APK}"
: "${KEYDIR:?Действующий каталог существующего проектного ключа}"
: "${ANDROID_SDK_ROOT:?Установленный Android SDK с build-tools 36.0.0}"
: "${JAVA_HOME:?Установленный полный JDK}"
export TRANSFER APK KEYDIR ANDROID_SDK_ROOT JAVA_HOME
python3 - <<'PY'
import json, os, shutil, stat, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(os.environ['TRANSFER']) / 'scripts/release'))
import android_release as android
import android_sign_package as signing

expected = '49e2ee65a8dd881085edf2934b72cf19985f28ee9918de37ce99eb1cd70efd08'
source = Path(os.environ['APK']).absolute()
keys = Path(os.environ['KEYDIR']).resolve(strict=True)
sdk = Path(os.environ['ANDROID_SDK_ROOT']).resolve(strict=True)
java = Path(os.environ['JAVA_HOME']) / 'bin/java'
assert source.is_file() and not source.is_symlink() and java.is_file()
assert android.digest(source) == expected, 'APK SHA mismatch; nothing signed'
before = signing.key_stats(keys)
out = Path(tempfile.mkdtemp(prefix='foto-build17-signed-', dir=Path.cwd()))
out.chmod(0o700)
bt = sdk / 'build-tools/36.0.0'
with tempfile.TemporaryDirectory(prefix='.input-', dir=out) as temporary:
    staged = Path(temporary) / 'unsigned.apk'
    with os.fdopen(os.open(source, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as src:
        assert stat.S_ISREG(os.fstat(src.fileno()).st_mode)
        with os.fdopen(os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as dst:
            shutil.copyfileobj(src, dst)
            dst.flush(); os.fsync(dst.fileno())
    assert android.digest(staged) == expected, 'Input changed while copying'
    payload = android.apk_payload(staged)
    android.run([str(bt / 'zipalign'), '-c', '-P', '16', '4', str(staged)], out)
    signed = out / 'Foto-5.7.3-build17-signed.apk'
    android.run([str(java), str(Path(os.environ['TRANSFER']) / 'scripts/release/SignExistingApk.java'),
        str(keys), str(bt / 'apksigner'), str(staged), str(signed)], out, dict(os.environ))
    assert signing.key_stats(keys) == before, 'Key metadata changed; reject output'
    assert android.apk_payload(signed) == payload, 'APK payload changed; reject output'
    metadata = android.apk_metadata(signed, sdk, out, '5.7.3', 17)
    android.run([str(bt / 'zipalign'), '-c', '-P', '16', '4', str(signed)], out)
    signed.chmod(0o600)
    (out / 'signing.json').write_text(json.dumps({'sourceCommit': '244ae32fc6dc1bf1199ea1bbd3c06a1e85e8948d',
        'inputSHA256': expected, **metadata}, indent=2) + '\n')
    print('PASS existing project certificate, unchanged payload, version and alignment')
    print('SIGNED_APK', signed)
    print('SHA256', metadata['apk_sha256'])
print('NOT INSTALLED; no server or application data changed')
PY
```

Проверка существующего production certificate выполняется `apk_metadata`, pinned fingerprint:
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
Если фактический сертификат установленной версии отличается, остановитесь, не удаляйте приложение
и не меняйте pin ради PASS. Подписание на HP и этот блок с реальным ключом в Cloud **не выполнялись**.

Перед обновлением Samsung S23 сравните сертификат установленного APK с подписанным результатом.
Установка допускается только как update с сохранением данных, без uninstall. На синтетическом
альбоме проверьте cold-start backup, background/resume, server Trash, Restore, отказ Android
в локальном удалении и повтор после согласия, а также Live Photo autoplay. Физический Android/iOS
и настоящий Synology/NFS остаются NOT TESTED в Cloud; не проверяйте удаление семейных фотографий.

## 4. Что этот комплект не разрешает

Нет deployment, production migrations/SQL/Redis, изменения retention/deletion policy, replay
старых intents или удаления оригиналов. Существующие recovery-proof, roots, ownership,
tombstone/receipt проверки не отключались. Настоящий HP cgroup OOM проверяется отдельно;
SIGKILL fixture подтверждает только реакцию runner на аварийный exit, а не отсутствие OOM на HP.
