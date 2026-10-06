# Cloud Media Provider через Shizuku: исследование и архитектура fork

Дата: 6 октября 2026. База приложения: `fff90e5dc4ce2d4ae1d2aa80994042156eee51a0`.
Устройство пользователя: **Samsung S23, Android 16, One UI 8.5**.
Исследование read-only; телефон, HP и production не изменялись.

## Вывод

Путь реален как **community pilot**: собственный Android CloudMediaProvider
можно добавить в разрешённый список через явное разрешение Shizuku. Root,
компьютер и `rish` для интегрированной активации не нужны, если на устройстве
доступны wireless debugging и необходимые shell-операции. Обычный sideload
без этой активации по-прежнему не обеспечивает platform admission.

Предыдущий документ исследовал обычные app API; его ограничение OEM/allowlist
не означает запрет пользовательского Shizuku-пути. Пользователь теперь явно
попросил исследовать именно этот вариант. Это не официальная OEM интеграция
и не утверждение о физическом успехе на его S23.

**Выбранная архитектура:** provider внутри «Фото», использующий существующую
Gallery библиотеку/сессию, и отдельный короткоживущий Shizuku UserService только
для активации/диагностики/отмены. Не переносить целиком сторонний REST client.
В этом исследовании изменяется документация, не добавляются неработающие
provider stubs или непроверенный privileged workflow в production APK.

## Какие реализации проверены

| Источник                            | Проверенное состояние                                                                     | Значение для fork                                                                                                                                                                        |
| ----------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Dreaming-Codes/immich-cloud-media` | release v1.1.0 от 20 апреля 2026, SHA `4ae062f0dbe0804dbf1186fc7bc155fa0e265df3`, GPL-3.0 | Реальный provider и встроенный Shizuku UserService; minSdk 34, api/provider 13.1.5. Не готовая безопасная интеграция с нашим server.                                                     |
| Immich PR #26779                    | closed/unmerged; head `259f4a8efd1feba90be5a8549332c5206c472f3a`                          | Реальный CMP + local Drift repository и ADB instructions. Автор сообщает physical picker/transfer/video testing. Upstream отказался принимать shell-assisted feature в основной продукт. |
| Immich PR #26802                    | closed/unmerged; head `029cc3274c90120712286737da65c42623783999`                          | Актуальные файлы содержат SAF DocumentsProvider, а CMP удалён. Старое описание PR утверждает обратное; source tree важнее description. SAF не равно Photo Picker CMP.                    |
| Community PR #15                    | open/unmerged; head `388815a979cf8af9488c17e4e2ed31bed36e145d`                            | Исправления v3 API, pagination, visibility, duration, video streaming; не исправляет Shizuku lifecycle/account isolation.                                                                |
| Community PR #18                    | open/unmerged; head `f8b9476da88876964a15c655d76fa6f3d8130d87`                            | Отдельное исправление media/album cursor projection; не считать частью PR #15.                                                                                                           |

Известные physical сообщения принадлежат community contributors, не Codex:
PR #15 сообщает Samsung Android 16 / Immich 3.0.3, библиотека около 29k assets.
Комментарий 16 сентября сообщает успех на S23 Ultra, но **crash/search failure
на обычном Galaxy S23** при большой библиотеке. One UI версия не указана.
Issue #12 описывает Pixel 9 Pro / Android 17: Shizuku Enable не приводил к
появлению provider; ADB затем позволил его выбрать, но albums были пустыми.
Это разные проблемы admission и API/library handling.

## Что выполняет Shizuku; почему rish не нужен

`ShizukuHelper.kt` в v1.1.0 вызывает `pingBinder`, `checkSelfPermission`,
`requestPermission`, затем `bindUserService`. AIDL `ShellService` выполняет:

```text
device_config override mediaprovider allowed_cloud_providers codes.dreaming.cloudmedia
```

Код не запускает rish и не требует терминала. Это shell UID 2000 в UserService,
а не `Runtime.exec` обычного приложения. Запуск команды непосредственно из
app UID не даёт тех же прав. Shizuku API предлагает публичный UserService;
`newProcess` deprecated/private, rish предназначен для интерактивного терминала.

Android 11+ позволяет первоначально сопрячь и запустить Shizuku на самом
телефоне через wireless debugging. На S23 это предполагает установку Shizuku,
Developer options, Wireless debugging/pairing, запуск сервиса и явное разрешение
для «Фото». Доступность при конкретных Samsung/Knox/Auto Blocker policies надо
проверить; исследование не доказывает, что Auto Blocker надо отключать.
Не менять эти политики автоматически и не расширять shell access приложению
через root, глобальные permission grants или отключение защит.

ADB — альтернативный способ выполнить те же команды из shell. Для целевой
UX внутри приложения он не нужен после on-device настройки Shizuku.

## Однократная активация и перезагрузка

AOSP Android 16 `DeviceConfig.setLocalOverride` хранит override в Settings.Config,
namespace `device_config_overrides`, key `mediaprovider:allowed_cloud_providers`.
SettingsProvider сохраняет Config в `settings_config.xml`. API применяет sticky
overrides на Android V/API 35+. Shell help описывает override как сохраняющийся
и игнорирующий server-updates **для одного ключа**.

По этой архитектуре override не исчезает от закрытия «Фото», остановки Shizuku
или обычной перезагрузки. Photo Picker сохраняет выбранный provider отдельно.
После активации provider работает под обычным app UID; Shizuku не должен
участвовать в запросах фотографий, previews или originals.

Non-root Shizuku сам не переживает reboot. Его нужно повторно запустить, если
после reboot понадобится новая privileged операция: изменение/отмена admission.
Это не равно обязательной повторной активации Photos после каждого reboot.
**На S23 такое поведение ещё не испытано.** OTA, Mainline MediaProvider update,
OEM policy, Rescue/reset или очистка системных settings могут изменить состояние.
Sticky allowlist также замораживает обновления этого одного ключа; приложение
должно показывать состояние и предлагать перепроверку после OS/module update.

До API 35 нельзя переносить этот вывод только по номеру Android: наличие и
эффект команд проверяются отдельно. Main minSdk Gallery остаётся 26; provider
компонент должен иметь API-conditional enablement, а pilot изолируется на
поддерживаемой версии без повышения требований всего приложения.

## Безопасная активация для «Фото»

Community-команда заменяет **весь** allowed list своим package. Она может
убрать Google Photos/Samsung/другие providers из списка. `clear_override`
при отключении также уничтожает любой предыдущий override. Так не копировать.

Нужны состояния `unsupported / Shizuku unavailable / permission denied /
admitted / selected / usable / failed / externally changed` и следующий flow:

1. Проверить API/module, установленный настоящий provider и его read permission,
   наличие нужных команд, cloud feature state, foreground Android user,
   Shizuku shell UID и явное разрешение. Успешная авторизация не равна admission.
2. Считать effective allowlist, **presence и value** предыдущего local override,
   текущий selected authority. Хранить private recovery journal до мутации.
3. Добавить только `de.opennoodle.gallery` к effective comma-separated packages,
   сохранив существующие записи. Если он уже допущен, не присваивать себе
   чужой override и не делать лишнюю запись. Authority — отдельное значение
   `${applicationId}.cloudmedia`, в allowlist находится package, не authority.
4. Сериализовать операции; повторно проверить snapshot перед записью. DeviceConfig
   не даёт общего compare-and-swap: при стороннем изменении остановиться.
5. Выполнить только per-key override. Не отключать
   `cloud_media_enforce_provider_allowlist` и не использовать глобальный
   `set_sync_disabled_for_tests`; другие namespace/keys не менять.
6. Проверить effective value и override read-back, PackageManager discovery,
   затем реальный Photo Picker. Shell может напечатать `Error:` при exit 0;
   command exit сам по себе не означает успех.
7. Предпочесть обычный выбор «Фото» в настройках Photo Picker. Не переключать
   пользователя с Google Photos молча. Можно открыть поддерживаемый settings
   flow; первый ручной выбор источника — часть однократной настройки.
8. При Disable восстановить прежний override или убрать **только собственный**,
   лишь если текущий override всё ещё равен записанному нами. Если состояние
   изменил другой инструмент, не стирать его. Восстанавливать previous selection
   только если пользователь просит и текущий выбор всё ещё наш.

Одновременно выбран один cloud provider; сохранение нескольких packages в
allowlist означает возможность выбрать их, не параллельное объединение облаков.
Установка provider сама по себе не меняет выбранный источник. Shell force-select
игнорирует allowlist в старом controller, но новый picker отдельно фильтрует
discovery; force-selection без admission не обеспечивает устойчивый результат.

Shizuku UserService должен иметь только typed AIDL операции read/admit/verify/undo,
fixed executable/argument arrays, caller validation, bounded output, timeout,
cancellation/binder-death handling и всегда unbind/destroy; `daemon(false)`.
Не выставлять generic `runCommand(String)` из Flutter и не передавать credentials,
server URL или media paths в shell service. App session используется только
в обычном provider/network процессе. Ни rish, ни постоянный privileged daemon
для этой схемы не нужны.

Uninstall не гарантирует удаление системного override. UI должен предлагать
Disable до удаления приложения и сохранять понятный manual recovery plan.
Самостоятельно clearing overrides без journal запрещён выбранной архитектурой.

## Почему нельзя просто перенести community APK/code

| Контракт/риск         | Проверенный результат в нашем fork                                                                                                                         | Минимальное направление адаптации                                                                                                     |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Sync                  | `sync.service.ts` требует session; `AssetsV1` запрещён. Community release использует V1; API-key sync даёт 403.                                            | Существующий Gallery `SyncStreamService`/AssetsV2; без второго независимого sync checkpoint client.                                   |
| Albums/duration       | Album DTO не содержит assets; duration — nullable integer milliseconds. Release ожидает старые контракты.                                                  | Штатный local album state или paginated search `albumIds`; existing durationMs. Version label 5.7.1 не определяет форму API.          |
| Visibility            | Default search not-locked может включать archive/hidden motion.                                                                                            | Canonical Photos visibility и доступные Shared Spaces/partners; Trash/Locked/hidden не утекут в picker.                               |
| Большие библиотеки    | PR #15 всё ещё читает whole sync `body.string()`; reported S23 crash.                                                                                      | Streaming sync и bounded query pages; callbacks без full network crawl/полного originals mirror.                                      |
| Account/cache         | Release использует fixed collection ID и global tracking/preferences; logout очищает credentials, не весь picker state.                                    | Server/user-scoped collection IDs, monotonic generation, tombstones, logout/switch invalidation, запрет старых IDs под новой session. |
| Local dedup           | Release сопоставляет filename+size.                                                                                                                        | Существующий verified checksum/local linkage; не угадывать duplicate filenames.                                                       |
| Download/video        | Release скачивает video original, затем ещё один temp copy; нет cancellation/retention bounds.                                                             | Existing authenticated HTTP client, video playback stream для preview, original по запросу, bounded owned cache/FD lifecycle.         |
| Native PR direct port | PR #26779 использует старый `duration_in_seconds`, count-based generation и несовместимые native server prefs; full Shared Spaces/stack query отсутствует. | Использовать идеи provider/cursor/Drift доступа; заново подключить к актуальному query/auth/lifecycle, не cherry-pick вслепую.        |

GPL-3.0 у standalone community app, AGPL-3.0 у Gallery/Immich. При копировании
сохранять license/attribution и обязательства исходников; Shizuku API — MIT,
AOSP — Apache-2.0. Не копировать чужие binaries/signing/config или весь scaffold.

## Изолированная реализация в fork

- Native `${applicationId}.cloudmedia`, exported и защищённый framework
  `com.android.providers.media.permission.MANAGE_CLOUD_MEDIA_PROVIDERS`.
  API-conditional component/resource, без загрузки API33 superclass на Android26.
  Изменение package ID или signing key не нужно.
- Native metadata/query repository над актуальным local Drift состоянием;
  разрешённые Photos правила остаются источником истины. Для доступа без Activity
  нужна bounded native projection/read-only DB handoff с schema/lifecycle guard,
  не запуск отдельного Flutter engine на каждую плитку. Уточнить bridge в coding
  task: совместное SQLite/WAL чтение, sync/migration lease, атомарный snapshot.
  Не вводить ещё одну библиотеку/asset identity или independent REST sync.
- Collection identity привязана к configured server + current owner/auth epoch.
  Generation монотонная, не `COUNT(*)`; изменения Trash/restore/delete/visibility
  отражаются в deleted-media delta. Account switch/logout немедленно запрещает
  открытие старых IDs и сбрасывает разрешённые platform caches/collection.
  Это критично после текущего Trash blocker.
- `HttpClientManager` уже имеет native persisted session, server mappings,
  authenticated OkHttp/headers/cookies и TLS policy. Переиспользовать, не передавать
  токены Shizuku и не создавать другую схему auth. Session ownership проверять
  на каждом open и после awaited network operation.
- Оригинал: существующий `/assets/{id}/original`, file streaming, CancellationSignal,
  bounded concurrent downloads/singleflight, seekable read-only FD, own leased
  cache/retention. Preview: existing bounded thumbnail/preview; видео playback
  endpoint с range support. Никакого full-buffer original или MediaStore import.
- Live/Motion still остаётся одним item; hidden companion не выводится отдельно.
  Оригинальные embedded Samsung bytes сохраняются лишь если original действительно
  содержит motion. Apple HEIC+MOV pair не становится полноценным Live Photo от
  одного `onOpenMedia` still FD. Не менять pairs и timeline autoplay ради picker.
- Flutter Advanced Settings: opt-in «Использовать Фото в системном выборе фото»,
  диагностика и Disable; Android-only native bridge, без iOS stubs/зависимостей.
  Штатные Share/Download остаются доступными без Shizuku и provider admission.
  Gradle/AGP/Kotlin, server API/schema и production workers не требуют изменения.

Telegram увидит cloud library только в entry point, который использует
совместимый системный Photo Picker. Его собственный gallery/MediaStore picker
не получит server-only items автоматически. То же относится к другим apps.

## Допуск на S23 / Android 16 / One UI 8.5

До implementation нельзя объявлять provider работающим только по источникам.
Для будущего pilot нужны:

1. Read-only inventory: Photo Picker/MediaProvider package/module version,
   Shizuku wireless launch/UID/permission, effective allowlist/override/feature,
   installed provider declaration и current selected authority. Не печатать
   credentials или всю DeviceConfig базу.
2. First enable без root/PC/rish; permission deny, timeout, отмена и binder death
   дают корректный failure, а не «готово». Проверить сохранение existing providers,
   admission, выбор «Фото» и реальную передачу ORIGINAL в receiving app.
3. Managed/external photo/video, HEIC, rotation/HDR, большой video/cancellation,
   многовыбор, network loss, seek, 30k+ assets и большой album без RAM spike.
4. Trash/restore/permanent delete, hidden motion/Locked, manual stacks, local/cloud
   dedup и Shared Spaces RBAC. Account A→B/logout не показывает cached A media.
5. Force-stop/relaunch «Фото», остановка Shizuku, phone reboot с Shizuku stopped:
   выбранные server-only файлы должны открываться без повторной активации.
6. Mainline/OTA update: admission/selection проверяются вновь; recovery не
   перезаписывает внешние настройки. Disable до/после reboot сохраняет исходный
   override, Google Photos и последующий пользовательский выбор источника.

Физические проверки не выполнены. APK/провайдер/системные изменения в этой задаче
не создавались. Проведено исследование repository/API/source, не native build.
Только документационные проверки нужны для текущего diff; ранее завершённые
Library, Trash и unsigned iOS artifacts остаются без изменений кода.

## Зафиксированные источники

1. [Community source/release v1.1.0](https://github.com/Dreaming-Codes/immich-cloud-media/tree/4ae062f0dbe0804dbf1186fc7bc155fa0e265df3), [ShizukuHelper](https://github.com/Dreaming-Codes/immich-cloud-media/blob/4ae062f0dbe0804dbf1186fc7bc155fa0e265df3/app/src/main/kotlin/codes/dreaming/cloudmedia/util/ShizukuHelper.kt#L37-L89), [ShellService](https://github.com/Dreaming-Codes/immich-cloud-media/blob/4ae062f0dbe0804dbf1186fc7bc155fa0e265df3/app/src/main/kotlin/codes/dreaming/cloudmedia/util/ShellService.kt).
2. [Immich #26779](https://github.com/immich-app/immich/pull/26779), [actual source](https://github.com/Dreaming-Codes/immich/tree/259f4a8efd1feba90be5a8549332c5206c472f3a/mobile/android/app/src/main/kotlin/app/alextran/immich/cloudprovider), [#26802 actual source](https://github.com/Dreaming-Codes/immich/tree/029cc3274c90120712286737da65c42623783999/mobile/android/app/src/main/kotlin/app/alextran/immich/cloudprovider).
3. [Community #15](https://github.com/Dreaming-Codes/immich-cloud-media/pull/15), [S23/S23 Ultra comment](https://github.com/Dreaming-Codes/immich-cloud-media/pull/15#issuecomment-5699371981), [#12](https://github.com/Dreaming-Codes/immich-cloud-media/issues/12), [#18](https://github.com/Dreaming-Codes/immich-cloud-media/pull/18).
4. [Official Shizuku API 13.1.5](https://github.com/RikkaApps/Shizuku-API/blob/a27f6e4151ba7b39965ca47edb2bf0aeed7102e5/README.md): shell UID, wireless launch, reboot, UserService, deprecated newProcess и rish.
5. [AOSP Android16 shell commands](https://github.com/aosp-mirror/platform_frameworks_base/blob/33b96ce8a122757002e5040ac59824bd7a262e00/packages/SettingsProvider/src/com/android/providers/settings/DeviceConfigService.java#L655), [SettingsProvider permissions/persistence](https://github.com/aosp-mirror/platform_frameworks_base/blob/33b96ce8a122757002e5040ac59824bd7a262e00/packages/SettingsProvider/src/com/android/providers/settings/SettingsProvider.java).
6. [AOSP tag mirror DeviceConfig storage/API35 applyOverrides](https://github.com/aosp-mirror-neo/platform_packages_modules_ConfigInfrastructure/blob/48c8ab0a72a2b2bec3266b0ffe588bb0695acca7/framework/java/android/provider/DeviceConfig.java#L1166-L1216), [setLocalOverride](https://github.com/aosp-mirror-neo/platform_packages_modules_ConfigInfrastructure/blob/48c8ab0a72a2b2bec3266b0ffe588bb0695acca7/framework/java/android/provider/DeviceConfig.java#L1355), [SettingsConfigDataStore](https://github.com/aosp-mirror-neo/platform_packages_modules_ConfigInfrastructure/blob/48c8ab0a72a2b2bec3266b0ffe588bb0695acca7/framework/java/android/provider/SettingsConfigDataStore.java). Official googlesource endpoint was unavailable; release-tag mirror source was inspected, not treated as Samsung firmware.
7. [AOSP MediaProvider shell vs app selection](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/78a0bebdc478a3e827618944f9998c5e21fc9712/src/com/android/providers/media/MediaProvider.java#L8032), [modern discovery](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/78a0bebdc478a3e827618944f9998c5e21fc9712/photopicker/src/com/android/photopicker/data/DataServiceImpl.kt#L578), [ConfigStore](https://github.com/aosp-mirror/platform_packages_providers_mediaprovider/blob/78a0bebdc478a3e827618944f9998c5e21fc9712/src/com/android/providers/media/ConfigStore.java#L376).
