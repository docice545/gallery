# iOS readiness «Фото»: технический аудит

Дата: **5 октября 2026 года**. Основа аудита — ветка `work`, commit
`171a1f5be28d7d93c1aa4c5b276c4bba27787475`. Это заключение по исходникам, а не подтверждение
работоспособности подписанной сборки. iOS implementation, signing, CI и production в рамках
аудита не изменялись; IPA не собирался, не подписывался и не устанавливался.

## Заключение и границы

Приложение уже имеет существенную iOS реализацию: общий Flutter UI, серверные функции,
PhotoKit sync и Save to Photos, Swift image/network APIs, фоновую загрузку, Share Extension и
Widget Extension. Обычные **Share и Download не являются Android-only**. Для готовой iOS версии
не нужен перенос всей функциональности с Android; нужны исправления жизненного цикла фоновых
задач, надёжная iOS build-only проверка, полноценная передача Live Photo пары и испытание
нативных путей на iPhone.

Различаются три уровня доказательств:

- **Реализовано в исходниках:** Dart/Swift пути и их регистрация найдены, контракты сопоставлены.
- **Требует исправления:** найден конкретный пробел или небезопасный порядок операций.
- **Требует физической проверки:** исходники имеются, но подпись, PhotoKit, системный Share,
  AVPlayer и фоновые ограничения нельзя подтвердить Flutter unit tests на Linux.

Приложение остаётся обычным IPA «Фото», без зависимости от SideStore API. Канал распространения
и бесплатная подпись — отдельная задача: см.
[`2026-10-05-ios-free-distribution-design.md`](2026-10-05-ios-free-distribution-design.md).
Этот аудит не обещает бессрочную бесплатную подпись или невидимое автоматическое продление.

Не входят в необходимые изменения: Android `key.jks`/alias `foto`/applicationId, production
server **5.7.1**, PostgreSQL/Redis/ML, размещение и deployment Big-LaMa, SSD layout, VPN/DNS/AWG
и внешний auto-stack worker. Production контракт остаётся в
[`2026-10-05-production-autostack-design.md`](2026-10-05-production-autostack-design.md).
Для проверки iOS не требуется переносить либо дублировать эти данные и сервисы.

## Функции текущей версии

Статусы относятся к указанному слою функции, а не к приложению целиком:

- `READY` — общая Dart/server logic уже реализована; новый iOS порт этого слоя не нужен.
  Это **не** утверждение, что signed iOS app проверен на устройстве.
- `NEEDS_IOS_IMPLEMENTATION` — конкретный iOS пробел либо дефект требует изменения кода/конфигурации.
- `NEEDS_TESTING_ON_MAC_IPHONE` — iOS путь найден, но необходимо подтвердить его компиляцию и/или
  поведение на macOS/iPhone; Android результат не переносится автоматически.
- `BLOCKED` — финальный iOS release/signing допуск отсутствует до прохождения явно указанных gates.
  Сам read-only аудит выполнению этих gates не равен.

| Функция / слой                                          | Статус                        | Причина и конкретное действие                                                                                                                                                                                                        |
| ------------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Photos feed: Flutter navigation/layout/filter/selection | `READY`                       | Общие Timeline/Drift/API; отдельный iOS экран не нужен. Media adapters проверяются отдельными строками                                                                                                                               |
| Dense feed: общая геометрия                             | `READY`                       | `timeline.widget.dart` + `fixed/segment.model.dart`, denseLayout не Android-gated; на iPhone проверить scroll/selection/overlays и размеры без нового layout port                                                                    |
| Face-aware framing                                      | `NEEDS_TESTING_ON_MAC_IPHONE` | Общая thumbnail geometry изменяется в этой работе; новый Pigeon API не нужен. Проверить вертикальные still/Live tiles, orientation и fallback. Здесь не заявлен успешный native test                                                 |
| Motion/Live autoplay                                    | `NEEDS_TESTING_ON_MAC_IPHONE` | Общий visible-item selector/one-shot + native_video_player существуют; проверить AVPlayer completion, scroll/route/lifecycle и still fallback. Механизм autoplay не менять                                                           |
| Apple Live Photo чтение / PhotoKit sync                 | `NEEDS_TESTING_ON_MAC_IPHONE` | PlaybackStyle/paired resource/iCloud paths имеются; проверить реальные Apple assets, limited/full access и iCloud-only export                                                                                                        |
| Apple Live Photo Save to Photos                         | `NEEDS_TESTING_ON_MAC_IPHONE` | Darwin saveLivePhoto реализован; проверить image/video identity, MOV/HEIC, cancellation/retry и отсутствие лишних копий                                                                                                              |
| Live Photo Share/import с сохранением пары              | `NEEDS_IOS_IMPLEMENTATION`    | Входящий attachment не содержит pair identity, исходящий Share даёт один файл на asset; расширить contracts и native resource transfer, см. раздел Live Photos                                                                       |
| Motion Photo embedded original                          | `NEEDS_TESTING_ON_MAC_IPHONE` | `.MP` идёт одним original файлом; сохранение байтов не подтверждает Apple Live Photo playback. Проверить PhotoKit Save/Share и явный still fallback                                                                                  |
| Photo/video access и permissions                        | `NEEDS_TESTING_ON_MAC_IPHONE` | iOS `.photos`, limited status и plist/macro paths есть; проверить denied/limited/full/Add-to-Photos, отзыв permissions и server-only browsing                                                                                        |
| Upload: очередь/server API                              | `READY`                       | Общие upload/cancellation/auth services уже имеются; новый сервер или Android-only upload port не требуется                                                                                                                          |
| Upload: local/iCloud resources и URLSession             | `NEEDS_TESTING_ON_MAC_IPHONE` | Реализованы origin/subtype/iCloud export и iOS URLSession upload; проверить metadata, pair, большие файлы, background callbacks и сетевой отказ                                                                                      |
| Automatic backup / background sync / execution          | `NEEDS_IOS_IMPLEMENTATION`    | BGTaskScheduler/URLSession paths существуют, но timeout/cancel не ждёт active phase futures до DB teardown; исправить drain и native result. Затем physical expiration/lock/reboot tests                                             |
| Pigeon/native registration и signatures                 | `NEEDS_TESTING_ON_MAC_IPHONE` | Семь Swift-enabled definitions статически соответствуют реализациям, lock/view intent intentionally Android-only; нужен Swift compile, а не новые заглушки                                                                           |
| Обычный исходящий Share                                 | `NEEDS_TESTING_ON_MAC_IPHONE` | share_plus iOS path, original staging/MIME/progress/cancel/7-day retention реализованы; проверить Photos/Files/third-party receivers и iPad popover                                                                                  |
| Обычный incoming Share Extension                        | `NEEDS_TESTING_ON_MAC_IPHONE` | share_handler и Swift extension имеются; проверить cold/warm launch, multiple attachments, revoked temporary file и upload после switching app                                                                                       |
| Обычный Download / Save photo/video                     | `NEEDS_TESTING_ON_MAC_IPHONE` | photo_manager Save + download tracking/import существуют; проверить PhotoKit denial, iCloud existing ID, retry/cancel и оригинальные metadata                                                                                        |
| Magic Eraser: editor/job/mask/save-copy logic           | `READY`                       | Общий Flutter editor и серверный original pipeline; Big-LaMa не переносится в iOS. Live/Motion output — отдельная статичная копия                                                                                                    |
| Magic Eraser: iOS gestures/preview                      | `NEEDS_TESTING_ON_MAC_IPHONE` | Проверить touch/zoom/brush, cancel и save-copy при lifecycle/network failure; нового native eraser engine не требуется                                                                                                               |
| Memories / AI Memories UI logic                         | `READY`                       | Общие zoom/pause/hide/delete/candidates и API/Drift; external AI Memories не переделывается, новый iOS generator не нужен                                                                                                            |
| Memories mixed photo/video UX                           | `NEEDS_TESTING_ON_MAC_IPHONE` | Проверить pinch/pan, pause/resume, действия поверх видео, кандидатов и обновление lane после sync на iPhone                                                                                                                          |
| Stacks / manual stack behavior                          | `READY`                       | Общие owned-asset Stack API create/add/remove/primary/dissolve; нет iOS worker. Manual suppression/owner boundaries и единственный external processor сохраняются                                                                    |
| Remote Trash / Restore / permanent delete logic         | `READY`                       | Общие Gallery Trash API и action/services. Restore возвращает capture chronology; Android local trash не является серверной корзиной                                                                                                 |
| Trash sorting/grouping по deletedAt                     | `NEEDS_TESTING_ON_MAC_IPHONE` | Исправление общего Flutter кода выполняется отдельно в этой работе; нужен iPhone UI regression check. Это не новый PhotoKit trash API или DB migration                                                                               |
| Удаление device copies / local Photos cleanup           | `NEEDS_TESTING_ON_MAC_IPHONE` | PhotoManager iOS delete существует; проверить пользовательский PhotoKit confirmation/denial. MANAGE_MEDIA/local-trash restore остаются Android-specific                                                                              |
| Authentication/session/API logic                        | `READY`                       | Общие login/OAuth/server API/session/endpoint logic и iOS device header имеются; login сохранение после update/re-sign проверяется отдельно                                                                                          |
| Server TLS / cookies / native session / WebSocket       | `NEEDS_TESTING_ON_MAC_IPHONE` | CupertinoClient/WebSocket используют общий URLSession; PKCS12/default TLS trust/cookies реализованы. Проверить login/logout, cookie expiry, endpoint switching и background auth на разрешённых endpoints                            |
| Server 5.7.1 API compatibility                          | `NEEDS_TESTING_ON_MAC_IPHONE` | Есть version/features/capability gates; чтение исходников не доказывает весь runtime набор на production. Проверить iOS client с неизменённым сервером, без deployment/DB writes ради аудита                                         |
| Local notifications                                     | `NEEDS_TESTING_ON_MAC_IPHONE` | Darwin initialization, permissions и downloader notification groups есть; проверить allow/deny, foreground/background и completion. Это не APNs                                                                                      |
| APNs/push                                               | `NEEDS_IOS_IMPLEMENTATION`    | Remote registration/token transport отсутствуют; Profile aps entitlement не создаёт push feature. Опциональная новая функция: потребует client/server APNs design и отдельного разрешения, не блокирует нынешние local notifications |
| Local filesystem / cache ownership                      | `NEEDS_IOS_IMPLEMENTATION`    | iOS clearCache удаляет весь Directory.systemTemp рекурсивно; ограничить owned cache subdirectories и защитить active exports/imports/uploads                                                                                         |
| HEIC/HEIF originals/images                              | `NEEDS_TESTING_ON_MAC_IPHONE` | PhotoKit/ImageIO и original file MIME paths имеются; проверить HEIC/HEIF ориентацию, decode bounds, metadata и receiver compatibility без forced conversion originals                                                                |
| Video playback                                          | `NEEDS_TESTING_ON_MAC_IPHONE` | native_video_player iOS и URLSession/cookie wiring есть; проверить MOV/HEVC/H.264/HDR, orientation, local/iCloud/remote, long-video seek и auth                                                                                      |
| Widgets                                                 | `NEEDS_TESTING_ON_MAC_IPHONE` | Memory/Random Widget Extension и App Group существуют; проверить auth thumbnail после signed update/re-sign                                                                                                                          |
| iOS project / Xcode / build-only CI                     | `NEEDS_IOS_IMPLEMENTATION`    | Устранить signing prerequisites в no-upload branch и неправильный artifact; Xcode Cloud pin/full codegen исправить, если этот route используется                                                                                     |
| Minimum iOS / entitlements                              | `NEEDS_TESTING_ON_MAC_IPHONE` | Targets 15/16/17 требуют явного support decision и archive verification; сохранять AppGroupId/entitlements согласованными                                                                                                            |
| Bundle identifier / signing requirements                | `BLOCKED`                     | Branded identity определена и не переименовывается; доступность profiles/capabilities и signed archive не подтверждены. Проверяется отдельным этапом на macOS/Xcode                                                                  |
| App Store / distribution acceptance                     | `BLOCKED`                     | Release/signing/device/privacy/capability acceptance gates не пройдены; канал и политика Apple требуют отдельного этапа. IPA и store deployment сейчас запрещены scope задачи                                                        |

Для `READY` общих слоёв остаётся обычная iPhone regression проверка — это не основание создавать
новую iOS implementation. Для функций с существующим native path нужны проверки, а не
предположительное переписывание Swift, SDK или signing.

Основные feature sources:

- `mobile/lib/presentation/widgets/timeline/live_photo_autoplay.dart`,
  `mobile/lib/presentation/widgets/timeline/live_photo_scope.widget.dart`,
  `mobile/lib/presentation/widgets/asset_viewer/video_viewer.widget.dart`.
  Autoplay не входит в предлагаемые iOS изменения и должен сохранить текущий механизм.
- `mobile/lib/presentation/pages/memory.page.dart`,
  `mobile/lib/presentation/widgets/memory/{memory_photo,memory_actions,memory_candidates}.widget.dart`,
  `mobile/lib/domain/services/memory.service.dart`,
  `mobile/lib/providers/infrastructure/memory.provider.dart`.
- `mobile/lib/presentation/pages/edit/magic_eraser.page.dart`,
  `mobile/lib/repositories/magic_eraser.repository.dart`. Preview ограничен по размеру; телефон
  передаёт mask instructions, а сервер использует свой original. Переносить Big-LaMa в app не нужно.
- `mobile/lib/presentation/actions/share.action.dart`,
  `mobile/lib/repositories/asset_media.repository.dart`: отмена подготовки, имена/MIME, staged files
  и retention **7 дней**. Android originalShare MethodChannel вызывается только под Android guard;
  iOS вызывает `Share.shareXFiles` с `sharePositionOrigin`. Завершение share sheet не доказывает,
  что принимающее приложение закончило чтение файла, поэтому staged files не удаляются немедленно.
- `mobile/lib/repositories/download.repository.dart`,
  `mobile/lib/services/download.service.dart`, `mobile/lib/repositories/file_media.repository.dart`.
- `mobile/ios/ShareExtension/{ShareViewController.swift,Info.plist}`,
  `mobile/lib/repositories/share_handler.repository.dart`,
  `mobile/lib/models/upload/share_intent_attachment.model.dart`.
- Feed/dense: `mobile/lib/presentation/widgets/timeline/timeline.widget.dart`,
  `mobile/lib/presentation/widgets/timeline/fixed/segment.model.dart`.
- Stacks: `mobile/lib/presentation/actions/stack.action.dart`,
  `mobile/lib/presentation/actions/manage_stack.action.dart`,
  `mobile/lib/domain/services/asset.service.dart`,
  `mobile/lib/repositories/asset_api.repository.dart`. Owned actions вызывают server Stack API;
  create/add/remove/primary/dissolve не создают второй auto-stack processor.
- Remote Trash: `mobile/lib/presentation/pages/trash.page.dart`,
  `mobile/lib/presentation/actions/restore.action.dart`,
  `mobile/lib/presentation/actions/delete.action.dart`,
  `mobile/lib/infrastructure/repositories/timeline.repository.dart`.
- Auth/TLS/API: `mobile/lib/services/auth.service.dart`, `mobile/lib/services/oauth.service.dart`,
  `mobile/lib/services/api.service.dart`, `mobile/lib/services/server_info.service.dart`,
  `mobile/lib/infrastructure/repositories/network.repository.dart`,
  `mobile/ios/Runner/Core/NetworkApiImpl.swift`, `mobile/ios/Runner/Core/URLSessionManager.swift`.
- Local notifications: `mobile/lib/main.dart`, `mobile/lib/providers/permission.provider.dart`,
  `mobile/lib/widgets/settings/notification_setting.dart`, `mobile/lib/utils/bootstrap.dart`.
- Files/HEIC/video: `mobile/lib/infrastructure/repositories/storage.repository.dart`,
  `mobile/lib/utils/original_file.dart`, `mobile/ios/Runner/Images/LocalImagesImpl.swift`,
  `mobile/ios/Runner/Images/RemoteImagesImpl.swift`,
  `mobile/lib/presentation/widgets/asset_viewer/video_viewer.widget.dart`.

### Live Photos: чтение, сохранение и передача — разные пути

`mobile/ios/Runner/Sync/PHAssetExtensions.swift` передаёт PhotoKit playbackStyle, включая
`.livePhoto`, в `PlatformAssetPlaybackStyle`. Локальный PhotoKit sync существует; это не только
отображение серверного MOV. Экспорт и загрузка local/iCloud originals используют photo_manager и
iOS background upload paths; их fidelity проверяется на настоящих Apple Live Photos.

Для Download серверного Apple Live Photo `DownloadRepository` на iOS создаёт две задачи, а
`DownloadService._saveLivePhotos` ждёт image/video и вызывает
`PhotoManager.editor.darwin.saveLivePhoto` через `FileMediaRepository`. Есть защита от двойного
import, cancellation пары, временные файлы и восстановление completed tasks. Существующий
PhotoKit asset также проверяется, чтобы повторное сохранение не создавало ненужную копию.

Android embedded Motion Photo с именем `.MP` сохраняется одним original файлом даже на iOS
(`download.repository.dart`, ветка `isAndroidMotionPhoto`). Это сохраняет исходные байты, но не
означает автоматическое преобразование в Apple Live Photo. При ошибке `PHPhotosErrorDomain`
сохранения пары `download.service.dart` имеет fallback к image-only: fallback нельзя выдавать
пользователю за успешно сохранённый Live Photo.

Входящий Share Extension принимает обычные media attachments, однако нынешняя Dart модель не
имеет paired-video reference/content identifier. Исходящий `AssetMediaRepository` подготавливает
один `_ShareFile` на asset, включая Live Photo, и передаёт обычные XFile. Поэтому просмотр и
Save to Photos пары уже реализованы, а **Live Photo fidelity при входящем/исходящем Share ещё
не реализована**. Два несвязанных файла в share sheet сами по себе эту проблему не решают.

## Pigeon и native APIs

Проверены все **9 файлов** `mobile/pigeon/*.dart`. Семь имеют Swift generation; два намеренно
Kotlin-only. `background_worker_api.dart` содержит несколько interfaces: foreground Host,
background Host и Flutter callbacks. Называть девять файлов девятью отдельными Host APIs неточно.

| Pigeon definition                 | Swift implementation и состояние                                                                                                                                                                                                   |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `native_sync_api.dart`            | `mobile/ios/Runner/Sync/MessagesImpl.swift`: все 14 методов присутствуют. Albums/full/delta/hash/cancel/Cloud ID реализованы. Local device trash — `UNSUPPORTED_OS`, restore — false; Cloud ID и persistent changes требуют iOS 16 |
| `local_image_api.dart`            | `mobile/ios/Runner/Images/LocalImagesImpl.swift`: requestImage/cancelRequest/getThumbhash; все аргументы, включая isVideo/preferEncoded/width/height, соответствуют generated protocol                                             |
| `remote_image_api.dart`           | `mobile/ios/Runner/Images/RemoteImagesImpl.swift`: requestImage/cancelRequest/clearCache; nullable width/height и ImageIO resize имеются в Swift                                                                                   |
| `permission_api.dart`             | `mobile/ios/Runner/Permission/PermissionApiImpl.swift`: все методы присутствуют; battery granted и MANAGE_MEDIA false — Android-specific shim, не PhotoKit permission API                                                          |
| `connectivity_api.dart`           | `mobile/ios/Runner/Connectivity/ConnectivityApiImpl.swift`: NWPathMonitor wifi/cellular/unmetered; VPN определяется эвристикой `.other`                                                                                            |
| `network_api.dart`                | `mobile/ios/Runner/Core/NetworkApiImpl.swift`: все 7 методов; PKCS12 picker/import/remove, headers/cookies, URLSession pointer и App Group                                                                                         |
| `background_worker_api.dart`      | `mobile/ios/Runner/Background/{BackgroundWorkerApiImpl,BackgroundWorker}.swift`: foreground/background Host APIs и вызов Dart onIosUpload/cancel; Android notification/configure на iOS no-op                                      |
| `background_worker_lock_api.dart` | Swift output отсутствует; `BackgroundWorkerLockService.lock/unlock` вызывают канал только на Android                                                                                                                               |
| `view_intent_api.dart`            | Swift output отсутствует; `view_intent_handler.provider.dart` возвращает Stub на iOS. Android external-view intent не является iOS Share Extension                                                                                 |

Сопоставлены также generated `.g.swift` protocols: отсутствующего метода либо расхождения
argument labels/types в семи Swift-enabled definitions не найдено. Это не заменяет Swift compiler.
Все обычные plugins регистрируются в `mobile/ios/Runner/AppDelegate.swift`; NativeSync публикуется
как FlutterPlugin. `BackgroundWorker.run` повторяет registration для собственного Flutter engine и
добавляет BackgroundWorkerBgHostApi. Добавлять отсутствующие Swift channels для lock/view intent
ради самого наличия Dart definitions не требуется.

## Permissions и фоновые задачи

`DevicePermissionService._gallery` имеет отдельный iOS `.photos` путь. `DevicePermissionRepository`
сохраняет limited/granted/denied/permanentlyDenied status; iOS не пытается запрашивать Android
storage/video/MANAGE_MEDIA через этот gallery path. PhotoKit persistent delta использует только
full `.authorized` access; limited access и iOS 15 получают full-sync fallback.

`mobile/ios/Runner/Info.plist` содержит Photo Library Read/Add, camera, microphone, Face ID,
local network и location usage descriptions; Podfile включает permission_handler photos,
notifications и location macros. Отсутствующие camera/microphone macros сами по себе не являются
блокером нынешнего image_picker path, который использует свой plugin. Нужны реальные denied,
limited, full и add-to-library scenarios; наличие строк в plist не означает выдачу permission.

Info.plist содержит background modes `fetch`/`processing` и два permitted identifiers.
`BackgroundWorkerApiImpl` выбирает identifiers из plist по suffix, поэтому branding не теряет их.
BGAppRefreshTask имеет короткий 20-second budget; BGProcessingTask и background URLSession
реализованы. Cookie/certificate configuration и patch background_downloader находятся в
`mobile/ios/Runner/Core/URLSessionManager.swift`. Wi-Fi name restrictions зависят от permission и
Wi-Fi Info entitlement; NWPathMonitor VPN heuristic проверяется отдельно на устройстве.

**Найден риск teardown после cancellation (высокий).**
`mobile/lib/domain/services/background_worker.service.dart`, `onIosUpload`, запускает
`Future.wait(localSync, remoteSync, hash, backup)`, затем `all.timeout`. При timeout callback
завершает cancellation token и немедленно возвращает пустой список; исходный `all` продолжает
выполнение. `_handleCleanup` после этого закрывает DataController, не ожидая active phase futures.
`cancel()` вызывает такой же cleanup. Native `cancelHashing`/`cancelSync` в `MessagesImpl.swift`
только сигнализируют Task cancellation и не ждут завершения. Возможны записи после закрытия DB и
callbacks после teardown Flutter engine. Также ошибки `onIosUpload` логируются и поглощаются,
поэтому native success callback не является достоверным подтверждением успешной синхронизации.

Нужно сохранить active operation futures, прервать/отменить операции и дождаться их завершения
до disposal DB/engine, согласовав это с ограниченным expiration grace period iOS. Результат
failure/cancellation должен корректно достигать native completion. Это изменение относится к
мобильному background worker; оно не затрагивает внешний HP auto-stack worker.

Android-only charging/trigger-delay controls уже скрыты на iOS в
`mobile/lib/widgets/settings/backup_settings/backup_settings.dart`. Android local trash sync
в `local_sync.service.dart` тоже guarded. Swift no-op для этих настроек — ожидаемое различие,
а не требование копировать WorkManager semantics на iOS.

## Auth, уведомления и локальные файлы

HTTP и WebSocket на iOS используют общий URLSession через CupertinoClient/CupertinoWebSocket
(`mobile/lib/infrastructure/repositories/network.repository.dart`). Native `NetworkApiImpl`
настраивает headers/server URLs/cookies, импортирует client PKCS12 identity в Keychain;
`URLSessionManagerDelegate` для обычного server trust использует default handling. Разрешение
arbitrary loads в ATS не равнозначно отключению проверки TLS certificates. Из source не следует,
что фактический сертификат/цепочка, cookie expiry, Basic/client-cert auth или server endpoint
switching испытаны на целевом iPhone. Для проверки не требуется изменять VPN/DNS/TLS production.

Общие login/OAuth/session/version/features пути имеются. Compatibility с server 5.7.1 проверяется
по реальным ответам и capability gates, а не сравнением одного номера client/server. Сохранение
login после install/update/re-sign — отдельный physical criterion с прежним bundle ID/App Group.
Общие remote Trash actions тоже существуют; iOS PhotoKit deletion device copies — другой путь с
системным confirmation. Android local-trash restore не обещается iOS пользователю.

Local notifications на iOS инициализируются DarwinInitializationSettings, имеют permission UI и
download/upload notification groups. `AppDelegate` устанавливает UNUserNotificationCenter delegate.
APNs registration, сохранение device token и server push delivery не найдены. Development
`aps-environment` только в Profile entitlements не является реализованным push. Push — опциональное
расширение scope; если оно потребуется, нужны отдельные APNs capability, registration/token lifecycle
и server delivery design, а не изменение текущих local notifications или production вслепую.

**Найден риск слишком широкой cache cleanup (высокий).**
`StorageRepository.clearCache` в `mobile/lib/infrastructure/repositories/storage.repository.dart`
сначала вызывает PhotoManager.clearFileCache, затем на iOS удаляет **весь** Directory.systemTemp
рекурсивно. Метод вызывается foreground/background upload services и из sync settings. Очистка не
проверяет владение подкаталогом или активность файла; нужно заменить её cleanup конкретных owned
cache directories и согласовать с active upload/export/import operations. Outgoing share использует
getTemporaryDirectory/outgoing_share; этот путь нельзя автоматически приравнивать к systemTemp,
но cache cleanup также должна сохранять его documented receiver retention. Не удалять временный
оригинал, который ещё читает PhotoKit/downloader/system share.

HEIC/HEIF image decode использует PhotoKit/ImageIO, исходящие originals не конвертируются ради
передачи. Это наличие подходящего native пути, а не гарантия любого codec/receiver. iPhone tests
должны включать EXIF orientations, large decode bounds, iCloud original, HEVC/HDR MOV, metadata и
отсутствие незапрошенной потери motion или conversion originals.

## Signing и build configuration

| Часть              | Фактическое состояние и необходимая проверка                                                                                                                                                               |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Flutter/Dart       | `mobile/mise.toml` и `mobile/pubspec.yaml` согласованы: Flutter **3.47.2**, Dart `>=3.12.0 <4.0.0`; обновление SDK не предложено                                                                           |
| Deployment targets | Runner/Pods — iOS 15, ShareExtension — 16, WidgetExtension — 17. Поддержка всей версии с extensions на iOS 15 из одного Runner target не следует                                                           |
| Branded identity   | Raw `Signing.xcconfig` содержит upstream IDs, но `branding/scripts/apply-branding.sh` перед сборкой задаёт `de.opennoodle.gallery`, App Group `group.de.opennoodle.gallery.share`, Team из branding config |
| Extensions         | Release IDs `de.opennoodle.gallery.ShareExtension` и `de.opennoodle.gallery.Widget`; все три targets используют согласованный `CUSTOM_GROUP_ID` и собственный `AppGroupId` plist key                       |
| Entitlements       | Runner Release: App Groups, Associated Domains, Wi-Fi Info. Profile дополнительно имеет development APNs entitlement; Profile нельзя выдавать за Release                                                   |
| Signing pipeline   | Fastlane имеет отдельные profiles для main/share/widget и TestFlight upload. Доступность соответствующих profiles/capabilities владельца в этом аудите не проверена                                        |
| Dependencies       | CocoaPods lock и Swift Package.resolved имеются; generated Swift/Flutter/OpenAPI code требует общего codegen. Нативная совместимость pins подтверждается сборкой на macOS                                  |
| Gallery CI         | `.github/workflows/gallery-build-mobile.yml` выбирает Xcode 26.2, устанавливает Flutter/Pods и выполняет codegen; при непустом version вызывает release/TestFlight lane                                    |
| Build-only gap     | Даже при пустом version ASC key и signing certificate импортируются безусловно. `flutter build ipa --no-codesign` не экспортирует signed IPA, а artifact всё равно ожидается в `mobile/ios/Runner.ipa`     |
| Xcode Cloud        | `mobile/ios/ci_scripts/ci_post_clone.sh` клонирует незакреплённый Flutter stable и не выполняет полный проектный codegen; если этот путь используется, он нерепродуцируем относительно текущих pins        |

Источники: `mobile/ios/{Signing.xcconfig,Podfile,Podfile.lock}`,
`mobile/ios/Runner.xcodeproj/project.pbxproj`, Runner/Share/Widget plist и entitlements,
`branding/config.json`, `branding/scripts/apply-branding.sh`,
`mobile/ios/fastlane/{Appfile,Fastfile}`, `.github/workflows/gallery-build-mobile.yml`.

Нельзя менять bundle ID ради упрощения подписи либо удалять extensions, молча считая исходную
функциональность сохранённой. Нужно проверить итоговый archive: resolved main/extension IDs,
Team, profiles, entitlements и `AppGroupId` должны совпадать, а обновление поверх той же identity
должно сохранять login и общие данные. Associated Domains и Wi-Fi Info могут быть ограничены
выбранным signing channel; этот вопрос уже отделён в предыдущем distribution design.

## Необходимые изменения и критерии готовности

Риск **высокий** означает потерю обещанной функциональности или возможный lifecycle/data failure;
**средний** — непроверенный нативный путь либо недостоверный build result. Это приоритет инженерной
проверки, а не наблюдение production отказа.

| Необходимое изменение                                                                                                                                                         | Риск                            | Критерий                                                                                                                                                             |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Исправить background cancellation/drain и достоверность native completion                                                                                                     | Высокий                         | При timeout/expiration/cancel нет DB access и callbacks после teardown; активные операции отменены и завершены, failure не сообщается как success                    |
| Ограничить iOS StorageRepository.clearCache собственными cache directories; учитывать active uploads/imports/exports и retention share files                                  | Высокий                         | Upload/cache clear не удаляет корень tmp и файлы, ещё читаемые PhotoKit/downloader/receiver; regression test проверяет ownership и active-file exclusion             |
| Добавить credentials-free macOS iOS compile/archive check; отделить signing/export от build-only; исправить artifact path и отсутствие обязательного artifact считать ошибкой | Высокий                         | Пустой version не импортирует ASC/certificates и не публикует ничего; current pins + codegen + Swift/Pods/SPM компилируются, доступен ожидаемый archive/app artifact |
| Для полноценного Live Photo Share добавить paired resource/identity в export/import contracts и iOS native path, сохраняющий Apple pair metadata                              | Высокий для Live Photo fidelity | Входящий Apple Live Photo и передача принимающему совместимому приложению сохраняют motion. Обычный image-only share остаётся отдельным явным вариантом              |
| Явно различать invalid-pair image fallback и успешный Live Photo import                                                                                                       | Средний                         | Пользователь не получает обещание сохранённого motion, когда PhotoKit сохранил только still; временные файлы и tasks всё равно корректно очищаются                   |
| Зафиксировать поддерживаемую minimum iOS с учётом Runner 15 / Share 16 / Widget 17                                                                                            | Средний                         | Итоговый archive и заявленная поддержка согласованы; для старших/младших ОС перечислены доступные функции, deployment target не поднят молча                         |
| Если используется Xcode Cloud, закрепить Flutter по project pin и включить полный codegen                                                                                     | Средний                         | Этот путь воспроизводит те же dependency/codegen inputs, что основной macOS build                                                                                    |
| Проверить signing совместимость итогового archive для всех трёх targets, не переименовывая IDs                                                                                | Высокий                         | Entitlements/profiles/AppGroupId согласованы; signed install/update сохраняет identity/auth/shared storage и заявленные capabilities                                 |

Необязательная платформенная parity: iOS аналог Android external view intent, локального trash
restore/MANAGE_MEDIA, Android Cloud Media Provider, media-trigger/charging lock semantics.
Это Android APIs; необходимые iOS сценарии реализуются через разрешённые iOS механизмы, а не
добавлением заглушек. Для basic browsing, Memories, Magic Eraser и обычных Share/Download новый
нативный порт не требуется; обнаруженные physical failures исправляются по результатам проверки.

## Проверки на iPhone и существующие tests

Unit/widget tests подтверждают общую логику, но не PhotoKit/signing/background/AVPlayer:

- Timeline: `mobile/test/presentation/widgets/timeline/{live_photo_autoplay,live_photo_scope}_test.dart`,
  `mobile/test/presentation/widgets/asset_viewer/timeline_preview_video_viewer_test.dart`.
- Memories: `mobile/test/presentation/widgets/memory/{memory_photo,memory_actions,memory_candidates}_test.dart`,
  `mobile/test/domain/services/memory_service_test.dart`,
  `mobile/test/repositories/memory_api_repository_test.dart`.
- Magic Eraser: `mobile/test/pages/edit/{magic_eraser_page,magic_eraser_editor_integration}_test.dart`,
  `mobile/test/repositories/magic_eraser_repository_test.dart`.
- Share/Download: `mobile/test/repositories/{asset_media_repository,download_repository,share_handler_repository}_test.dart`,
  `mobile/test/services/download_service_test.dart`,
  `mobile/test/unit/presentation/actions/share_action_test.dart`.
- `mobile/test/platform/background_worker_native_files_test.dart` проверяет строки native source,
  а не жизненный цикл задач; для найденного drain риска нужен behavioral regression test.
- Feed/dense/shared stacks/auth имеют существующие tests:
  `mobile/test/presentation/widgets/timeline/dense_row_layout_test.dart`,
  `mobile/test/presentation/widgets/timeline/dense_timeline_overlays_test.dart`,
  `mobile/test/unit/presentation/actions/manage_stack_action_test.dart`,
  `mobile/test/unit/presentation/actions/stack_action_test.dart`,
  `mobile/test/repositories/auth_api_repository_test.dart`,
  `mobile/test/services/auth.service_test.dart`, `mobile/test/services/oauth_service_test.dart`.
  Новые Trash date и face-framing tests этой работы должны проверять общую логику, но не служат
  свидетельством PhotoKit/native validation. Для filesystem cache ownership нужен отдельный
  regression test с active-file exclusion, без операций над реальными iPhone originals.

Обязательные physical gates: разрешения denied/limited/full и Add-to-Photos; вертикальные
Apple Live Photo и Android Motion Photo, HEIC/JPEG/MOV/HEVC, iCloud-only originals; ориентация и
metadata после Save/Share; cancel одного из компонентов пары, restart/retry без лишних копий;
Share Extension из Photos/Files и принимающие системный Share приложения, в том числе iPad
popover; Memories zoom/pan/pause/hide/delete/candidates на mixed media; Eraser drawing/zoom,
cancel/save-copy при сетевом отказе; background expiration, lock/reboot, Low Power/Low Data,
Background App Refresh off, force-quit, permitted Wi-Fi и auth/cookies; Widget и Share Extension
после signed update/re-sign. iOS scheduling не проверяется обещанием точного интервала запуска.

В рамках этого аудита выполнены чтение и сопоставление исходников, Pigeon/Swift контрактов и
registration, разбор всех iOS plist/entitlements. Здесь не заявляется успешный прогон Flutter
tests текущей работы, Swift compilation, archive export, signing или испытание на устройстве.
Приёмка face-aware framing и результаты отдельных запусков фиксируются после их фактической
проверки; они не отменяют перечисленных iOS gates.
