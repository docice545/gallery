# Волшебный ластик: реализация и результаты проверки

Проверено 5 октября 2026 года в Codex Cloud. Продолжена уже начатая работа,
без reset/rebase/squash и без повторной реализации предыдущих задач.
Исходный HEAD этой части: `5928803825f85c1807f71d8c9e40a9b65a6329b1`.
Он включает предыдущую работу по timeline, версиям, брендингу и Share/Download,
а также исходный проверенный `07f7a8a8e98a52ba7bcd70a30c3b8018a00775c0`
и исправление memory_candidate. Итоговый feature commit находится поверх него;
его SHA можно получить через `git log -1 --format=%H` после fast-forward ветки.

## Реализовано

В существующем мобильном редакторе добавлен «Волшебный ластик»: кисть и её размер,
добавление/стирание маски, undo/redo/reset, zoom/pan, запуск обработки,
ожидание/отмена, До/После и явное «Сохранить копию». Кнопка доступна для
синхронизированной собственной фотографии при настроенном серверном сервисе.
При старом/ненастроенном сервере обычный редактор продолжает работать.
Локальная несинхронизированная фотография сначала требует штатного upload.

Переиспользованы Flutter editor/navigation, authenticated API transport,
Sharp/orientation, доступ Gallery к disk/S3 original, штатный upload ingestion,
quotas/checksums, generic asset metadata и metadata/thumbnail jobs. Existing ML
не содержит inpainting; его зависимости не менялись. Добавлен отдельный
опциональный приватный CPU service, а не новая мобильная тяжёлая модель.

Телефон получает только previews до 1600px, передаёт asset ID и нормализованные
strokes. Original читается сервером из своего storage и не проходит через
телефон туда-обратно. Preview downloads ограничены 8MiB и отменяемы.
Нет внешних AI API, telemetry или исходящих сетевых вызовов во время inference.

Сохранение создаёт обычный новый static JPEG в managed upload storage. Сохраняются
owner, visibility, capture instant/offset, upright orientation/dimensions и
allowlist camera/GPS/description metadata. Provenance в `gallery.magicEraser`
содержит sourceAssetId, sourceTimeZone, model, jobId и stillOnly. API не перезаписывает
NAS original. Повторный Save не создаёт дополнительный asset. Исходные Live/Motion
связи, видео и stacks остаются; копия не наследует stack или motion link.
Внешний production auto-stack может позднее сгруппировать такую копию по своей
политике. Исключение по provenance — возможная отдельная интеграция владельца.

## Модель и ресурсы

Big-LaMa TorchScript, upstream LaMa Apache-2.0, выбранный established IOPaint
artifact: **205669692 bytes / 196.14MiB**.

```text
https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt
SHA-256: 344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9
```

Checkpoint не коммитится и не скачивается приложением. Проверка SHA обязательна
до загрузки; artifact inspect и реальная CPU inference выполнены. Требуются
новый образ `gallery-inpainting:docice-work`, CPU Torch 2.10.0 и изолированные
FastAPI/Starlette/Uvicorn/multipart/Pillow/NumPy dependencies. Existing Gallery ML
requirements, Gradle/AGP/Kotlin, mobile manifests/lockfiles не менялись.

Одна активная inference, до трёх ожидающих, два CPU threads; auth/admission
выполняются до multipart parsing. Один API process/session, один worker/container.
Область вокруг маски обрабатывается до 512px и компонуется в исходное разрешение.
Лимиты: 36MP, 64MiB, 64 strokes, 8192 points, максимум 75% painted area.
Нативная inference не прерывается принудительно: отмена удерживает lane до её
завершения и отбрасывает результат. Model references освобождаются после 300s
простоя; allocator/Torch runtime могут удерживать часть RSS. Unsaved sessions
временные, срок жизни один час; restart теряет preview, сохраняя original.

Cloud измерения на AMD EPYC 7763, два Torch threads:

| Проверка | Время | Peak RSS |
| --- | --- | --- |
| Cold model load | 0.881s | — |
| Inference 256×256 | 1.651s | 640.3MiB |
| Inference 512×512 | 4.565s | 860.6MiB |
| Полный 12MP pipeline, output 4000×3000 | 5.722s | 1033.2MiB |

Это synthetic fixtures, не измерения на i3-9100T и не оценка качества на личных
фотографиях. Для HP предусмотрен CPU fallback, начальный container limit 3GiB
и два CPU. Ориентир — секунды/десятки секунд, возможны большие задержки; нужны
фактические latency/RSS и проверка влияния на ML/AI Memories.

OpenVINO/UHD630 исследованы, но backend/FFT conversion/ускорение не реализованы
и не обещаются. MAT отвергнут из-за research-only лицензии и CUDA machinery;
GMCNN — существующий Intel Open Model Zoo вариант для отдельного сравнения;
Stable Diffusion не добавлен. MobileSAM исследован как optional tap selection,
но segmentation не входит в первую brush-based версию.

## API и БД

Новые owner-gated маршруты, добавленные без изменения существующих endpoints:

```text
GET    /api/assets/:id/magic-eraser/capabilities
GET    /api/assets/:id/magic-eraser/source
POST   /api/assets/:id/magic-eraser
GET    /api/assets/:id/magic-eraser/:jobId
GET    /api/assets/:id/magic-eraser/:jobId/preview
DELETE /api/assets/:id/magic-eraser/:jobId
POST   /api/assets/:id/magic-eraser/:jobId/save
```

OpenAPI spec и TypeScript SDK обновлены; ignored Dart API client сгенерирован
и проверен. **Новых миграций/таблиц/Drift/Pigeon APIs нет.** Полный existing
migration startup прошёл на свежей disposable PG; `No schema drift detected`.
Версия server остаётся 5.7.1 через прежний `BUILD_VERSION=5.7.1`.

## Проверки

| Проверка | Результат |
| --- | --- |
| dart format changed source/tests | 10 files, 0 changes, exit0 |
| Full mobile `dart analyze --fatal-infos` | No issues found, exit0; повторено после API codegen |
| Relevant mobile regression suite | 627 tests / 70 unique test files passed, exit0 |
| Из них новые Magic Eraser tests | 67 passed: model18, repository24, page17, editor4, action4 |
| Повторный focused run после SDK codegen | 115 tests passed, exit0 |
| Server regressions + Magic Eraser | 798 tests / 11 suites passed, включая 57 новых, exit0 |
| Whole-server build/postbuild и TypeScript check | passed, exit0 |
| OpenAPI/Dart/TS SDK generation + TS SDK build | passed, exit0 |
| Touched server ESLint | zero warnings/errors, exit0 |
| Touched server/i18n Prettier | passed, exit0 |
| Localization | 17 new keys во всех 10 required locales, sorted/unique JSON и placeholders совпадают |
| Python pytest с настоящей проверенной моделью | 56 passed, 0 skipped, exit0 |
| Ruff check/format | passed; 9 Python files formatted |
| Docker build/runtime HTTP | passed: UID1000, readonly filesystem, CPU model, health/auth401/multipart, full-size result и temp cleanup |
| Actual Gallery HTTP → Big-LaMa → save asset → PG/filesystem | 11 contracts passed, exit0 |
| Existing history/schema/native/signing/dependency preservation | ancestor/diff checks passed |

Основная regression suite включает existing dense timeline, muted one-shot
autoplay, meaningful-scroll/new-viewport rules, Memories zoom, stacks,
version/branding, incoming/outgoing Share, permanent save и uploads.

Сквозной opt-in helper `server/test/magic-eraser-real-asset.e2e.mjs` запускает
настоящий Nest ApiModule с localhost disposable PostgreSQL/Redis и настоящим
Big-LaMa sidecar. HTTP регистрация/upload синтетического JPEG с Orientation6,
capture +03:00, stack и связанным MP4; mask auth/DTO checks; processing; Save;
actual existing metadata/thumbnail handlers; owner/date/timezone/orientation1,
640×960, filename/checksum/on-disk bytes/provenance checks; повторный Save;
SHA original/video и stack/live-link preservation. Другие ML/geodata workers
не запускаются, metadata/thumbnail handlers не mock-аются. Production URL/БД
не используются. Подробная инструкция воспроизведения находится рядом с helper.

## Диагностики, которые не скрыты

- В основном Flutter run было 10 сообщений `dart_isolate.cc(1403)` о VM finalizer
  в existing timeline/branding paths. Этот тип диагностики встречался до ластика;
  все assertions и run завершились exit0. Новые 67 focused tests прошли без этих
  сообщений. Это не подтверждение физической стабильности Flutter на телефоне.
- Python: два deprecation warnings — Starlette TestClient/httpx и `torch.jit.load`.
  Они не приводят к пропуску real model test. Новый runtime не заменяется на
  непроверенный model format ради подавления warning.
- Server unit tests: existing Node WASI experimental warnings. Реальный API
  helper: existing Nest wildcard-route auto-conversion, отсутствие SSR fixture
  и fresh-DB warnings до применения миграций. Schema drift отсутствует.
- Первый Docker runtime выявил реальные права COPY: root-owned source mode600
  не читался UID1000. Исправлен Dockerfile `COPY --chown=1000:1000`; rebuild и
  повторный HTTP smoke прошли. Cloud TLS CA передавался только временным BuildKit
  secret helper, без добавления cloud trust material в production Dockerfile.
- Первоначальный Dart format запуск не мог писать analytics config в readonly
  `/home/agent`; исправлены XDG paths среды. Повторная проверка exit0/0 changes.
- Финальный lint нашёл порядок трёх новых registry imports; исправлено, повторный
  lint exit0. Broad Prettier вне scoped tasks отмечает generated spec/SDK; тот же
  check на неизменённом HEAD тоже exit1. Сохранён штатный generator output, без
  массового formatting diff. Existing whole-server format из предыдущей задачи
  также отмечает неизменённый `1793400000000-FixMemoryCandidateSchema.ts`.

## Что осталось проверить

Android SDK в Cloud отсутствует: native APK/Telegram/Samsung Gallery здесь не
собирались и физически не запускались. Linux не предоставляет macOS/Xcode/iPhone:
native iOS/PhotoKit и Apple Live Photo UX требуют отдельной проверки.
CPU/RAM/visual quality на HP, UHD630 acceleration и tap segmentation не подтверждены.
Native original replacement не предлагается; результат всегда отдельная копия.

Точные безопасные команды владельцу HP, включая Docker metadata, только новый
inpainting service + только immich-server, проверку остальных container IDs,
mobile codegen/APK/applicationId/старого signing certificate:
[2026-10-05-magic-eraser-hp.md](2026-10-05-magic-eraser-hp.md).
Дизайн: [2026-10-05-magic-eraser-design.md](../2026-10-05-magic-eraser-design.md).
Модели/лицензии/первичные источники:
[2026-10-05-magic-eraser-research.md](../2026-10-05-magic-eraser-research.md).

Никаких production deployment, release, main merge, signing key generation,
APK/IPA/model checkpoint commits или изменений внешних AI Memories/carousel/
auto-stack scripts не выполнено. Cloud setup additions протестированы и сохранены
как draft для environment settings; автоматическая публикация среды не выполнялась.

## Все изменённые файлы

**Мобильный редактор и tests**

```text
mobile/lib/domain/models/magic_eraser.model.dart
mobile/lib/presentation/actions/edit_asset.action.dart
mobile/lib/presentation/pages/edit/edit.page.dart
mobile/lib/presentation/pages/edit/magic_eraser.page.dart
mobile/lib/repositories/magic_eraser.repository.dart
mobile/test/pages/edit/magic_eraser_editor_integration_test.dart
mobile/test/pages/edit/magic_eraser_page_test.dart
mobile/test/repositories/magic_eraser_repository_test.dart
mobile/test/unit/domain/models/magic_eraser_test.dart
mobile/test/unit/presentation/actions/magic_eraser_edit_action_test.dart
```

**Server API, registries и tests**

```text
server/src/controllers/index.ts
server/src/controllers/magic-eraser.controller.spec.ts
server/src/controllers/magic-eraser.controller.ts
server/src/dtos/magic-eraser.dto.ts
server/src/repositories/index.ts
server/src/repositories/magic-eraser.repository.spec.ts
server/src/repositories/magic-eraser.repository.ts
server/src/services/index.ts
server/src/services/magic-eraser.service.spec.ts
server/src/services/magic-eraser.service.ts
server/test/magic-eraser-real-asset.e2e.mjs
```

**Private inpainting service и tests**

```text
inpainting/.dockerignore
inpainting/.gitignore
inpainting/Dockerfile
inpainting/README.md
inpainting/compose.example.yml
inpainting/gallery_inpainting/__init__.py
inpainting/gallery_inpainting/app.py
inpainting/gallery_inpainting/config.py
inpainting/gallery_inpainting/engine.py
inpainting/gallery_inpainting/jobs.py
inpainting/gallery_inpainting/mask.py
inpainting/pyproject.toml
inpainting/requirements-test.txt
inpainting/requirements.txt
inpainting/tests/test_app.py
inpainting/tests/test_engine.py
inpainting/tests/test_mask.py
```

**Локализации и generated API**

```text
i18n/de.json
i18n/en.json
i18n/es.json
i18n/fr.json
i18n/it.json
i18n/nl.json
i18n/pl.json
i18n/ru.json
i18n/zh_Hans.json
i18n/zh_Hant.json
open-api/immich-openapi-specs.json
packages/sdk/src/fetch-client.ts
```

**Design/research/validation/HP instructions**

```text
specs/2026-10-05-magic-eraser-design.md
specs/2026-10-05-magic-eraser-research.md
specs/testing/2026-10-05-magic-eraser-e2e.md
specs/testing/2026-10-05-magic-eraser-hp.md
specs/testing/2026-10-05-magic-eraser-validation.md
```
