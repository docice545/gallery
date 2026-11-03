# Live Photo Timeline: обязательный допуск к выпуску

Уточнение владельца в задаче [Issue 18](https://github.com/docice545/gallery/issues/18):
любая регрессия Live Photo в основной ленте блокирует выпуск. Относится к Build 36,
дальнейшему Android UI Build 37, анимациям, удалению, навигации и оптимизации производительности.
Канонический [Issue 17](https://github.com/docice545/gallery/issues/17) сохраняет свой scope.

## Что сохраняется

Исходный runtime fix [PR 16](https://github.com/docice545/gallery/pull/16) не переписывается:
активность маршрута определяется по live AutoRoute segments; ModalRoute, TickerMode,
foreground, видимость, selection и playback lease остаются независимыми ограничениями.
В этом follow-up изменены тесты и CI, а не `live_photo_scope.widget.dart`, scheduler или player runtime.
Постоянный `route=true`, Viewer warmup и новые периодические таймеры запрещены как обход причины.

## Автоматические обязательные проверки

[Build Mobile](../../.github/workflows/build-mobile.yml) содержит два именованных job:

1. **Live Photo timeline non-regression** — без path/job filter, на каждом PR и push main/release.
   [Общий запуск](../../mobile/scripts/live_photo_regressions.sh) использует уже существующие
   scope, autoplay, presentation, thumbnail и native-viewer widget suites. Ошибки не подавляются,
   output сохраняется при failure. Кодгенерация и dependency resolution используют pinned mise/frozen lock.
2. **Live Photo native decoded motion** — после первого gate, hosted Android emulator API 35,
   animations enabled. Повторно использует существующие
   [native script](../../mobile/scripts/android_native_motion_test.sh) и
   [integration fixture](../../mobile/integration_test/timeline_native_motion_test.dart):
   настоящий ExoPlayer / PlatformView, синтетическое HTTP-видео, auth headers и Range,
   продвижение native position, одно завершение без перехода ко второму видимому кадру.
   Фото пользователя, production endpoint и production signing material не нужны.

Оба gate входят в `needs` unsigned Android, trusted-host Android signing и root iOS build jobs.
`failure`, `cancelled`, `skipped` и отсутствие тестового запуска не являются PASS.
Права branch protection не проверены из этой среды; названия выше должны быть required checks
при настройке правил репозитория. Наличие YAML не означает, что правила уже включены на GitHub.

Widget-тест дополнительно требует, чтобы до положительной native position не было
`onPreviewStarted` / `position-advanced`, а после неё был один callback и один marker.
Native emulator-тест требует порядок:

```text
selected → native-ready → play-request-accepted → position-advanced
```

Он также наблюдает не больше одного смонтированного native preview и отсутствие каскадного
воспроизведения второго фото после завершения. Это не аппаратная проверка всех ExoPlayer instances Samsung.

| Сценарий | Автоматическое покрытие | Обязательная физическая проверка |
| --- | --- | --- |
| Cold start прямо в ленту, без Viewer | `live_photo_scope_test`: cold AutoRoute replacement, stale `isActive=false`, modal/ticker true | Запуск установленного FOTO из завершённого процесса на Samsung |
| Видимая Live Photo действительно движется | Native emulator: HTTP bytes + decoded position + ordered stages | Визуальное движение объектов видео и соответствующий `position-advanced` |
| Scroll → остановка → возобновление | Scope/autoplay: immediate stop, visibility threshold, meaningful movement, stable source | Реальная длинная лента, медленный/быстрый scroll и остановка |
| Selection enter/exit | Scope/thumbnail: stop, stable one-shot budget, no extra selection/lease | Один tap/long press не выбирает посторонние фото; после выхода корректное дальнейшее playback |
| Viewer → back | Scope: inactive route stops, return rearms, stale callback rejected | Реальный Viewer с Live и обычным фото, затем back |
| Minimize → resume без kill | Scope: foreground gates, pending source cancellation/retry | Реальное сворачивание/возврат, включая исходный Build 35 сценарий |
| Не более одной Live Photo | Scheduler lease, maxConcurrent widget assertion, native preview count/no cascade | Визуальное и логовое наблюдение нескольких видимых Live Photo |
| Анимации / 120 Hz | Lifecycle/disposal/gesture assertions; emulator animations не выключены | Profile-mode Samsung traces, UI/raster p95/p99, budget 8.33 ms, jank и отсутствие зависания |

Scope-тест использует настоящий AutoRoute с fake preview; native fixture использует настоящий
player в изолированном MaterialApp. Ни один отдельно не доказывает cold start всего установленного
FOTO на Samsung или плавность 120 Hz. Скриншот обложки и успешный `play()` недостаточны.

## Проверка перед ручной подписью

[Read-only checker](../../mobile/scripts/require_live_photo_ci.py) используется в существующем
Gallery mobile и root Build Mobile workflows **до обращения к signing credentials**. Оба Live Photo
job используют переданный reusable `ref` (либо event SHA), как и сборка. Для exact checkout SHA требуется
успешный последний push-run `build-mobile.yml`, оба успешных Live Photo job, полный Flutter suite
и release tooling в точном attempt, а также успешные `test.yml` и `static_analysis.yml` на том же SHA.
Внутри этих workflows каждый обязательный Backend/Web/mobile/CLI/ML/i18n/schema/E2E/analysis job
проверяется отдельно: overall success с skipped job не принимается. На push проверки запускаются
полностью, включая изменения только документации/metadata; PR сохраняет обычные path filters.

- PR-run не принимается за доказательство exact source: GitHub тестирует synthetic merge checkout.
- Старый green run не перекрывает более новый failed/running run того же SHA.
- Missing/duplicate/skipped/failed gate, недоступный GitHub API и неполные данные блокируют подпись.
- Это защита штатных mobile workflows, не проверка установленного HP и не разрешение
  запуска сторонних release scripts. При отдельной HP-сборке эти же условия входят в ручной handoff.
- Android signing не стартует по PR/push. Legacy `mich` job требует manual caller и
  явный `android_release=true`; default false. Unsigned CI не получает keys/environment secrets.
- iOS unsigned build остаётся доступен без подписных credentials. Включить signed path через
  reusable inputs в PR/push нельзя.

## Samsung receipt — обязательный отдельный результат

До выпуска сохранить: exact source SHA; APK SHA256, applicationId/versionCode и certificate digest;
модель Samsung/Android/One UI; режим 120 Hz; сценарий запуска и timestamp; обезличенную цепочку
четырёх markers; запись реального движения; UI/raster profile trace с метриками.
Использовать отдельный тестовый альбом с синтетическими still/motion pairs.
Не публиковать media IDs, фотографии, серверные токены или личные URL.

Выполнить все восемь строк таблицы. Cold start должен начинаться после завершения процесса,
Viewer до первой Live Photo не открывать. Отдельно выполнить minimize/resume без kill.
В selection проверить вход/выход и последующее движение ленты, сохраняя one-shot semantics PR 16;
прохождение этого сценария не закрывает P0 массового выделения из Issue 17.
Для анимации удаления использовать только синтетические данные с подтверждённым scope удаления.

**Текущий статус: Samsung NOT TESTED, 120 Hz NOT MEASURED, acceptance INCOMPLETE, release NO-GO.**
Обязательные jobs и изменённые Dart/native assertions подготовлены, но не исполнялись в этой Linux-среде
без Flutter/Android SDK; на SHA `86eeb429f` оба hosted Live Photo gate уже PASS ([run](https://github.com/docice545/gallery/actions/runs/41694382792)),
но полный Flutter suite имеет 6 failures. Следующий candidate SHA должен получить собственные результаты. Python fixture tests проверяют инструменты
и условия gate, а не воспроизведение видео. После интеграции результатов статус обновляется только
по точному source/artifact и фактически выполненным проверкам, без переноса PASS с другого SHA.
