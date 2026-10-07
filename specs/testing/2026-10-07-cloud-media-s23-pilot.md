# «Фото»: CloudMediaProvider / Shizuku pilot

## Repository implementation

This implements the accepted [design](../2026-10-06-cloud-media-shizuku-design.md).
It is an **opt-in Android 15/API 35+ pilot**, targeting the user's S23 / Android 16 /
One UI 8.5. It is not a claim that Samsung's picker or Telegram has been physically
tested. iOS, normal Share/Download and the external HP workers remain independent.

`de.opennoodle.gallery.cloudmedia` is a real `CloudMediaProvider`, protected by
`com.android.providers.media.permission.MANAGE_CLOUD_MEDIA_PROVIDERS`. Gallery does
not receive that system permission. Manifest resource gating disables the provider
on older Android. Its foreground settings bridge and Shizuku admission service are
separate from media reads; picker requests do not start a Flutter engine or Shizuku.

The catalog reads the existing `immich.sqlite` in read-only transactions, schema 38.
There is no second REST sync, asset import, library mirror or server migration. Its
SQL follows the remote arm of the current merged timeline projection: current
owner, permitted partners/Shared Spaces, personal hide rules, timeline visibility,
no deletion/Trash, no Locked/archive, stack primary only. Linked motion companions
are excluded even if their visibility was incorrectly set to timeline. Unknown
original sizes are omitted rather than fabricated. Existing normal Gallery sync
must first provide the remote assets and their EXIF size/type metadata.

Collection IDs include the endpoint/account/auth epoch and a streamed digest of
eligible metadata and album membership. A changed digest requests a **full picker
collection reset**, including deletions; the implementation deliberately does not
claim incremental tombstones. Media IDs remain stable within the same session.
The digest is cached while the DB/WAL revision is unchanged; pages return at most
200 rows with a versioned continuation token. A changed snapshot invalidates old
tokens. DB changes are observed and notifications coalesced. This is a correctness
tradeoff: a large library is not mirrored or held in RAM, but changes can require
a full system-index resync. Measure picker resync cost on the S23 before treating
this pilot as a finished large-library production implementation.

Logout/account/server/token changes fail old IDs closed and require a fresh opt-in.
Opening a descriptor rechecks the current catalog and the server's asset ACL /
Trash / visibility using the existing native HTTP session. Cached picker thumbnails
are controlled by Android; verify their removal after account changes/Trash on the
physical device. No claim of instant OEM cache purge is made.

Image previews use existing thumbnail/preview endpoints (not originals). Originals
are fetched only on selection, via seekable proxy descriptors and authenticated
HTTP ranges. Each reader caches at most four 512 KiB chunks; at most four readers
are active (8 MiB aggregate chunk cache, plus framework/caller buffers). A 50 GiB
synthetic source exercises seeking without allocating that file. Cancellation,
descriptor release, logout/Trash, changed ETag/length and invalid ranges fail closed.
Preview downloads stream to a private owned directory, have a 16 MiB bound and four
concurrent slots, and are unlinked after opening; the receiving FD remains readable.
No MediaStore copies or Share/import/export temp directories are touched.

Live/Motion appears as one logical still item. A byte-exact Samsung original can
retain an embedded motion payload if the original actually has one. A separate
Apple HEIC+MOV pair is **not** advertised as a reconstructed native Motion Photo
through one still FD; Android MIME extension stays `NONE`. Timeline autoplay is
unrelated and continues using Gallery's hidden paired video.

## Privileged boundary and recovery

Shizuku API/provider is pinned to 13.1.5. A non-daemon `UserService` must run as
wireless-debugging **shell UID 2000**; root and foreign Binder callers are rejected.
Typed AIDL exposes only inspect/admit/undo/cancel and the reserved service teardown.
It accepts no arbitrary command, path, account, cookie or server token.

The fixed commands inspect `device_config help`, the per-key effective value and
local override, the feature/enforcement flags, current Android user and selected
system provider. The only write is:

```text
device_config override mediaprovider allowed_cloud_providers <validated merged list>
```

Existing packages, Google Photos and the verified selected provider are retained.
No global enforcement flag is disabled. No provider is silently selected. A private
durable recovery journal is committed **before** this write; exact read-back is
required before activation. Bounded command output, timeouts, cancellation, Binder
death and engine detach retain the journal for uncertain outcomes.

Disable immediately stops Gallery media access even when Shizuku is unavailable.
System undo happens only with shell permission, on the same Android user, and when
the current override still exactly equals the value written by this app. It restores
the previous override or clears only this owned key. External changes are not
overwritten. A write already made by another tool is never claimed as ours. If undo
is pending, restart wireless Shizuku and press Disable again. Do not uninstall or
clear Gallery's app data before resolving the journal: that can destroy the only
record needed for safe recovery.

The API 35+ local override is designed to persist after app/Shizuku stop and reboot;
normal media reads need neither Shizuku nor wireless debugging. OEM policy, OTA or
settings reset may change admission. Recheck diagnostics after those events; no
physical Samsung persistence result is claimed. Shizuku itself generally needs a
new wireless-debugging start after reboot for diagnostics/activation/undo.

## Первый запуск на Samsung S23 / Android 16 / One UI 8.5

1. Установить APK, подписанный **существующим HP release key `foto`**, поверх текущей
   «Фото». CI validation APK имеет другой тестовый сертификат и не обновит эту
   установку. Не удалять рабочее приложение ради обхода ошибки подписи.
2. Войти в «Фото», дождаться обычной синхронизации библиотеки. Убедиться, что выбран
   нужный аккаунт; никаких миграций Anna и повторного импорта выполнять не нужно.
3. Установить официальный [Shizuku](https://shizuku.rikka.app/). В Samsung включить
   параметры разработчика → «Беспроводная отладка» в доверенной Wi-Fi сети.
4. В Shizuku выбрать запуск через беспроводную отладку, выполнить сопряжение с
   кодом на этом же телефоне и запустить Shizuku. Root, rish и компьютер не нужны.
5. В «Фото» → Настройки → Расширенные настройки → «Фото в системном выборе фото»
   нажать «Включить» и разрешить запрос Shizuku именно для «Фото».
6. Дождаться подтверждения допуска; открыть «Настройки выбора фото» и **самостоятельно**
   выбрать «Фото» как облачный источник. «Диагностика» должна различать «допущен» и
   «выбран системой». Если OEM не предоставляет выбор, остановить проверку, не
   отключать глобальные защиты и не выполнять обходные shell-команды.
7. Открыть приложение, которое действительно вызывает **системный Android Photo
   Picker**, и выбрать фотографию, оригинал которой есть только на сервере. Проверить
   её открытие у получателя. Своя галерея Telegram может не вызывать системный picker;
   для неё гарантированный путь остаётся «Поделиться» / «Скачать на устройство».
8. Проверить server-only видео, большой файл, перемотку, отмену и отсутствие сети.
   Проверить, что Trash, Locked, hidden Motion-компаньон и другой аккаунт не видны.
9. Проверить Shared Spaces, stack primary, MIME-фильтр, альбомы и библиотеку >30k.
   Проверить Trash → restore → permanent delete и смену аккаунта уже при открытом
   picker; старый идентификатор не должен открываться под новым аккаунтом.
10. Проверить Live/Motion как один элемент, отдельно timeline autoplay. Сравнить
    Samsung Gallery/Share результат с реальным исходным форматом; не считать обычную
    HEIC+отдельный MOV полноценным Android Motion Photo.
11. Остановить Shizuku и проверить обычный выбор файла; перезагрузить S23 и проверить
    повторно. После reboot запустить Shizuku заново только если нужны диагностика /
    изменение допуска. Проверить сохранение Google Photos в доступных источниках.
12. Нажать «Выключить», проверить отсутствие медиа «Фото» в picker. Если показано
    ожидающее восстановление, запустить Shizuku и повторить «Выключить». Проверить
    сохранность прежнего allowlist / Google Photos и отсутствие чужих изменений.

## CI and signing handoff

The manual `Gallery Build Mobile` workflow's `android_media_pilot=true`,
`build_target=android`, empty `version` lane performs locked full codegen, native
JUnit tests, Flutter regressions, an actual Android emulator motion-playback test
and a release-mode validation APK, without store upload or production credentials.
Its debug-certificate APK is intentionally labeled as validation, not HP release.

For a later physical S23 build on HP, use the existing checkout/cache/signing setup:

```bash
# Только проверка и сборка mobile; production server/services не меняются.
cd /opt/gallery-fork
git status --short
# При локальных изменениях остановиться; не reset/stash автоматически.
test -z "$(git status --porcelain)" || exit 1
test "$(git branch --show-current)" = work || exit 1
git fetch origin work
git merge --ff-only origin/work
git rev-parse HEAD
cd mobile
# Выполнить штатный locked codegen, если он ещё не выполнен для этого HEAD.
flutter build apk --release --build-name=5.7.2 --build-number=6
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --verbose --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
"$ANDROID_HOME/build-tools/36.0.0/aapt" dump badging \
  build/app/outputs/flutter-apk/app-release.apk
```

Expected application ID: `de.opennoodle.gallery`; version: `5.7.2`, build `6`.
Expected permanent release certificate SHA-256:
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
Do not generate/replace/read credentials from the existing key or properties file.
Native build and physical acceptance results belong in the validation handoff;
this architecture document does not manufacture a successful run.
