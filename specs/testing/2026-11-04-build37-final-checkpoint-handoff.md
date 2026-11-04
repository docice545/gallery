# FOTO Build37 — полный checkpoint и передача работы

Снимок состояния **2026-11-04T11:19:28+00:00**. **Production NO-GO.** По просьбе пользователя приоритет переключён на сохранение всего задания перед лимитом. Новые задачи/архитектура не начаты. Этот документ охватывает весь #17, связанные A–D #18 и дополнения; источник статусов отдельных требований — [единый BUILD37_CHECKLIST.md](https://github.com/docice545/gallery/blob/codex/issue17-smart-timeline/BUILD37_CHECKLIST.md).

## 1. Что восстанавливать в новой сессии

| Направление | Существующая ветка / PR | Последний SHA исходников, которому относятся текущие CI |
|---|---|---|
| FOTO5.7.3+37 | `codex/issue17-smart-timeline`, [Draft PR20](https://github.com/docice545/gallery/pull/20), база `codex/foto-build37-android-ui` /6c8882bbf | `b01961b7d53f3a42293f1dfaea4d0578f77558f4` |
| Backend + совместимость Build36 /5.7.3+36 | `codex/issue18-backend-contract-rating`, [Draft PR21](https://github.com/docice545/gallery/pull/21), база PR19 | `451b475c25fb66aaacabfff73fc6b5799b7c39a4` |
| Сохранённый аудит Build36 | `codex/issue18-cross-platform-audit`, [Draft PR19](https://github.com/docice545/gallery/pull/19) | `2a4183a0268920d72752bf06a2c5205e7e84e7ad` |

Финальный коммит **документации** каждой ветки следует за указанным code SHA. Его точный HEAD опубликован в body PR20/21 и итоговом сообщении; после получения checkout проверить `git rev-parse HEAD` и `git show --stat HEAD`. Документальный checkpoint использует `[skip ci]` только чтобы не отменять ещё работающие проверки исходников. **Его HEAD не имеет собственного полного CI и не является release candidate.** Проверки не отключены в workflow; для выпуска потребуется обычный push без skip-ci и полный CI именно нового выбранного SHA. Не выдавать checks родителя, PR merge checkout, skipped/cancelled или старый artifact за проверку финального SHA.

Рабочие каталоги текущей среды: `/workspace/gallery-build37`, `/workspace/gallery-backend-fixes`, исходный `/workspace/gallery`. В последнем сохранены три прежних незакоммиченных файла:

- `mobile/test/presentation/pages/slideshow_page_test.dart`
- `mobile/test/presentation/widgets/asset_viewer/timeline_video_viewer_test.dart`
- `mobile/test/presentation/widgets/timeline/justified_timeline_widget_test.dart`

Не переносить/перезаписывать их без анализа. Наши исправления опубликованы в указанных ветках. Не создавать новый проект/ветку без необходимости; не ждать отсутствующего исполнителя. Пользователь разрешил точечный Backend в отдельном PR21 и согласовал **FOTO icons v1, commit ccdb8a892**. Согласование v1 повторно не запрашивать; крупный редизайн требует отдельного просмотра.

Запреты сохраняются: merge, force-push, deployment, production/HP/NAS/контейнеры/фото/EXIF/keystore, новые release keys, release signing, установка на пользовательский телефон без отдельного разрешения. Hosted ephemeral CI/debug emulator — отдельная проверка, не подпись оригинальным ключом и не аппаратная приёмка.

## 2. Объём всего Build37, уже сохранённый в коде

Ниже навигация по существующей матрице, а не новый список требований. AUTO означает конкретные автоматические проверки, не Samsung PASS. Полный актуальный body #17/#18 был перечитан через API; при продолжении перечитать вновь, включая оба уточнения §12.

| Пункты матрицы | Сохранённая реализация / доказательство | Остаток |
|---|---|---|
| V1–V4, §1 Viewer | Компактные translucent controls, равные icon-only actions/48dp targets; actual PhotoView single tap/swipe/pinch/pan, pan увеличенного фото не листает. Реальный Viewer→pencil→editor→SaveCopy тест. `asset_viewer.page.dart`, `asset_page.widget.dart`, `bottom_bar.widget.dart`, `viewer_gestures_test.dart`, `viewer_editor_copy_test.dart` | Аппаратные H1/H2/H7; current full CI |
| E1–E8, §1/2/12 + темы | Один dock56dp+SafeArea, замена содержимого; старый engine, undo/redo/SaveCopy/Cancel, Magic Eraser, IME/landscape/font2×, zoom/pan/history. Light/dark/system live switch, explicit override, одинаковые экспортируемые pixels. `mobile/lib/presentation/pages/edit/`, `mobile/test/pages/edit/` | H7 и настоящий original/motion/backup H4; изменения геометрии не начинать заново |
| I1–I2, §11 | Утверждённые оригинальные FOTOv1,20/22/24dp, light/dark/states/mapping/semantics. `specs/design/foto-icons-v1`, `mobile/lib/presentation/widgets/icons/proposal/` | TalkBack/контраст/касания на Samsung H7; v1 уже APPROVED |
| A1–A6, §3/4 | Server/local list и server grid: swipe только reveal, обратный swipe закрывает; tap bin→одна FOTO confirmation. Trash assets перед удалением метаданных; fresh paged IDs/ownership. Local-album exit только после OS receipt+fresh DB empty, не loading. `album_selector.widget.dart`, `local_album.page.dart`, `local_timeline.page.dart`, `delete.action.dart` | Реальные OS denial/partial/permissions H4; не добавлять backup/второй FOTO dialog |
| S1–S6, §8 | Typed exact asset IDs, one tap→one ID, rapid1→many→1, refresh/date/range/album transitions; fresh snapshot/revision/account/endpoint/stack membership до mutation. Device-only/server/album scopes, late ACK/new selection, reconciliation и Undo guards. `multiselect.provider.dart`, `timeline_drag_region.dart`, `delete.action.dart`, `cleanup.service.dart` | H4/H2; тесты не заменяют Android consent |
| K1–K2, §7 | Stack2→1 cover/child: SQL representative, persisted membership, Viewer/cache/sync/reopen/error/restore; живой asset цел, не косметическое скрытие badge. `remote_asset.repository.dart`, server stack-trash-selection medium tests | H4, повтор текущих server/full Flutter jobs |
| G1–G3, §5 | Ghost Trap lift→twist/ribbon→видимая корзина→reaction/reflow,640ms/180ms reduced, batch1 representative, cached capture, ACK-gated result/rollback/duplicate tap. `mobile/lib/presentation/widgets/` Ghost widgets + action tests | Samsung120Hz H2/H4; не объявлять WOW/FPS по widget clocks |
| L1–L3, §6/8 | Compact/equal-width selection actions, SafeArea/font-scale, уведомление впереди Years/Months/All, hit testing после исчезновения. Dense overlay и actual selection tests | Повторить последние визуальные критерии пользователя H2/H4 |
| D1–D2/M1–M4, §9/10 | Persisted Classic/Google-like, adaptive Justified2–5, chronology/stacks; один существующий fixed-top transient date+cache-only location/IgnorePointer; Classic headings. Raw-height nearest-row и реальный ScrollPosition anchor/boundary исправлены. `row_layout.dart`, `timeline.widget.dart`, `timeline_scrubber.widget.dart`, justified/overlay/settings tests | **Визуальная калибровка Google/Samsung не завершена**: matched H3, затем только измеренное изменение. Не делать fixed3columns. Factor1.55 сохранён |
| P1–P5, локализация | Единый locale resolver list/detail/search/Timeline, ru/en/cache/offline/source fallback. Причины: list локализовал, detail использовал raw route; Vostochnoe/Vostochnoye alias; Timeline имел отдельный raw path. IDs/coords/EXIF/album titles неизменны, нет per-tile geocoding. `place_name.service.dart`, `place_names.provider.dart`, `place.model.dart`, pages/tests | Samsung H8; массовое regeocoding запрещено |
| F1–F2/Q1, Live Photo/120Hz | PR16 cold-start/lifecycle/route/visibility/max1 lease/ACK gates сохранены; stage events и реальная native position в emulator gates. Opt-in profile collector/VM CLI/raw UI-raster/p50/p95/p99/jank с source SHA | Все8 Samsung H1 + H2; текущие native jobs ещё не все закончены |
| C1–C8/C10–C14, #18 | A аудит выполнен; API digest unchanged; Backend races исправлены отдельными воспроизведениями; safe release/unsigned iOS/Android/provenance/175 Build35 migrations. PR16 Web/Backend source перенесён адресно. Core metadata/asset/contract source на обоих code SHA согласован | B/C/D частично: current full CI, final artifacts, H4–H6; production NO-GO |
| C9, офлайн | Доказанный preview/cache dead wait исправлен; реальные SQLite restart/decoded pixel/catalog tests PASS. Подробнее ниже | Android final completion receipt и Samsung offline/reconnect; не выдавать symptom как полностью закрытый на устройстве |

21 синтетический Flutter screenshot редактора, paired themes и geometry receipts: [editor review](https://github.com/docice545/gallery/blob/b01961b7d53f3a42293f1dfaea4d0578f77558f4/specs/design/editor-dock-review/README.md). Viewport393×688/image387×688/dock56+24 на render fixture393×852. Это **не** Samsung. Четыре Places render и причина: [places review](https://github.com/docice545/gallery/blob/b01961b7d53f3a42293f1dfaea4d0578f77558f4/specs/design/places-localization-review/README.md).

## 3. C9: причина, изменение, проверки

Failing-before `1554795b0`: [job126494512513](https://github.com/docice545/gallery/actions/runs/41806413261/job/126494512513)1077PASS/1ERROR — доступный durable thumbnail не выдавался до завершения зависшего preview HTTP request. Это подтверждённый software path; полнота объяснения симптома реального Samsung ещё не доказана.

Fix `86e1a3b6e` в Build37 / shared `866f7c4a5` в Build36: `mobile/lib/presentation/widgets/images/remote_image_provider.dart` независимо разрешает versioned small thumbnail и preview, ограничивает provisional decode250px short side, поздний low-res не понижает уже готовый preview. Нет таймеров/Viewer warmup/route=true; server/session/revision/base-path cache identity и SQLite queries не меняются.

[Focused5a job126522116398](https://github.com/docice545/gallery/actions/runs/41814613750/job/126522116398) и **[current b019 focused job126527687220](https://github.com/docice545/gallery/actions/runs/41816263055/job/126527687220):1084PASS/0FAIL/0ERROR/0SKIP**. Specific files:

- `mobile/test/presentation/widgets/images/remote_image_provider_http_test.dart`: pending preview/cached pixels; preview-first/late-thumbnail no downgrade.
- `mobile/test/presentation/widgets/timeline/offline_timeline_restart_test.dart`: настоящий Timeline/route service, файловая SQLite, реальный raster RGBA, mixed/local-only/empty, sync error, close/reopen DB+cold Flutter cache, pending auth/preview, Backend return; linked local/server pair остаётся одной плиткой.
- `mobile/test/domain/services/sync_stream_service_test.dart`: actual version/stream network errors сохраняют exact SQL IDs/localId, без ACK/OS delete.
- `mobile/test/medium/repository_context.dart`: optional file-backed DB fixture dependency. При порте в Build36 параметр сначала был пропущен; **451b475c2** добавил его. Оба current Static PASS, full Flutter данной ветки ещё pending. Не переносить UI37 ради теста.

Исправленные ошибки фикстуры не выдаются за product fixes: FakeAsync filesystem/raster boundaries, asynchronous DB close, повторный auth-user insert (Store already upserts). Assertions не ослаблялись.

Native boundary widget-теста использует файловый stub. `tools/original-noodle-gallery/assert_offline_pixels.py` и `foto_offline_emulator_smoke.sh` отдельно требуют две резкие synthetic markers внутри photo area, а не цвета chrome/дату. Detector4PASS + настоящий ImageMagick round-trip. Job Backend54 reported PASS, но доступные phase-аннотации кончались на credentials; одного статуса недостаточно. Новый обязательный post-action step требует atomic `completed exit=0` и повторную проверку **обоих** online/offline PNG. Current E2E receipt ещё ожидается; не повторять product smoke после старта ради PASS.

На этом code checkpoint дополнительно завершились: [PR full Flutter coverage job126528302476](https://github.com/docice545/gallery/actions/runs/41816263048/job/126528302476) PASS; [source unsigned universal APK126529719751](https://github.com/docice545/gallery/actions/runs/41816253697/job/126529719751) PASS; [native job126531381907](https://github.com/docice545/gallery/actions/runs/41816263055/job/126531381907) PASS с **position173→1509ms**, native-ready160×90, play-request-accepted→position-advanced→ended→lease-revoked; authorizedReads1/rejectedReads0. Это реальный ExoPlayer на эмуляторе, не восемь Samsung сценариев. Source full Test, остальные native/full/compat jobs всё ещё не завершены.

## 4. Оставшиеся задачи, причины и следующий шаг

### Реальные ошибки исходного кода

На момент checkpoint нет новой воспроизведённой **неисправленной** product source ошибки по завершившимся проверкам. Это не означает отсутствия ошибок: full/native/compatibility jobs не завершены, Samsung C9 и визуальная калибровка остаются непроверенными. Подтверждённые selection/stack/metadata/C9/layout ошибки исправлены и имеют отдельные tests/commits в матрице. Если текущий test упадёт — сначала сохранить failing evidence и воспроизвести; не менять expected rating/digest/ID/pixels ради PASS.

| Остаток / класс | Файлы / установленная причина | Следующий конкретный шаг |
|---|---|---|
| Full current CI / verification | `.github/workflows/test.yml`, `build-mobile.yml`, `smart-timeline.yml`; snapshot ниже. Pending/cancelled ≠ PASS | Дождаться/прочитать каждый job исходного SHA. Matrix fail-fast мог отменить amd64 после ARM setup failure; отменённые тесты нужно выполнить, не считать пройденными |
| SQL bootstrap / infrastructure | [job126527971725](https://github.com/docice545/gallery/actions/runs/41816253607/job/126527971725): Docker image pull exit1 до checkout/tests. Детальная причина pull недоступна | После завершения общего Test-run повторить bootstrap job на том же SHA; сохранить первый failure. Запрос rerun уже получил HTTP403 «workflow already running», повтор **не состоялся** |
| ARM registry / infrastructure | [PR job126531820319](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820319), [source job126533064725](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533064725): `toomanyrequests`,3 fetch attempts/30s+60s exhausted доtests. `.github/scripts/pull-ci-images.sh`, `test.yml` | Дождаться окончания run; один обоснованный bootstrap rerun. При повторе проверить auth/registry service и bounded diagnostics; не менять pinned digest/архитектуру, не retry-away product failures |
| Backend iOS setup / infrastructure, cause unknown | [job126534313545](https://github.com/docice545/gallery/actions/runs/41817664042/job/126534313545): use-mise exit1 доtests; available annotations не содержат причины. `original-noodle-gallery-compatibility.yml` | После окончания run повторить только setup-failed job. Если воспроизводится — получить toolchain logs/добавить bounded diagnostics; не считать simulator/product failure установленным |
| Hosted ENOSPC / исправлено, новый запуск требует проверки | Cache-unit runner и PostgreSQL layer после APK. `original-noodle-gallery-compatibility.yml`, `test_ci_build_diagnostics.py` | Current cache job уже PASS в PR20; проверить offline build cleanup + final receipt. Cleanup только hosted: preserve APK SHA256, удалить generated intermediates/isolated Gradle data, сохранить SDK/Java/source. HP не затронут |
| Native/unsigned iOS / verification | `android_native_motion_test.sh`, `integration_test/`, `build-mobile.yml`, `ios_build_only.sh` | Дождаться real position native gate, затем dependent unsigned iOS. Старые IPA не current candidate; ни device install, ни signing автоматически |
| C9 phone / hardware + possible follow-up code | `remote_image_provider.dart`, above tests/native cache; software reproduction закрыто, Samsung symptom повторно не проверен | Сохранить app data/cache; cold offline restart после успешной загрузки, Wi-Fi/mobile, resumed app, server return, local-only/empty. При провале собрать server/account/route/cache evidence, без массовой очистки/скана |
| §9 density / device-calibrated UI work | `fixed/row_layout.dart`, justified tests, factor1.55 retained | На одном Samsung/scale получить matched FOTO/Google media/screenshots2–5; измерить density3. Только после этого адресная calibration и regressions; пока visual parity не заявлена |
| Samsung remainder / hardware | Viewer/editor/themes/icons/selection/trash/stacks/Ghost/place code выше | H1–H4/H7/H8 по device procedure, actual IDs/source bytes/OS receipts + 120Hz profile; не подменять tests/synthetic renders |
| iPhone / hardware | `mobile/ios`, SideStore helper, permissions/editor/offline/motion | H5 installation/refresh/entitlements/expiry/test flows владельцем; simulator не является phone acceptance |
| HP / external execution | `scripts/release/server_build.sh`, `android_release.py`, `require_live_photo_ci.py`, safe-update tools | Проверенный clean SHA/CI, build/export/cert/ABI/version, staged backup/restore/upgrade. Только после отдельных разрешений; команды ниже и в release handoff |

Оставшиеся source-debugging задачи не переданы отсутствующему владельцу. В новой сессии один исполнитель продолжает весь объём.

## 5. Backend blockers и разделение веток

API contract fix уже опубликован/перенесён; hash baseline не заменён. Backend failing-before `a62a372bc`, fix `a957d5583` (Build37 equivalent `764207889`): stale extraction revision guard для3→null; coherent PostgreSQL snapshot + serialized sidecar writer для отдельной3→0; strict XMP errors сохраняют pending edit.109 real PostgreSQL/XMP medium tests и162 metadata unit tests PASS ранее. Exact historical Web interleaving без логов не объявлен доказанным. Ключевые файлы: `server/src/services/metadata.service.ts`, `server/src/repositories/asset.repository.ts`, `server/src/repositories/metadata.repository.ts`, `server/test/medium/specs/services/metadata-rating-race.spec.ts`, `server/src/services/metadata-sidecar-snapshot.spec.ts`. Full current Server/Web/E2E rerun ещё обязателен.

PR21 reviewable отдельно от UI37. Build36 и37 versionCode/артефакты не смешивать. Merge любых PR — только отдельное решение пользователя.

## 6. С чего продолжить на HP, без автоматического выполнения

[Проверенные инструкции Docker/universal APK/unsigned iOS](2026-11-04-build36-build37-release-handoff.md) актуальны:5.7.3+36/+37, Java21 поmobile/mise.toml, Android SDK36, frozen deps/codegen, original certificate, universal arm/arm64/x64, exact SHA/locks/labels/digests, Build35 baseline175migrations. API digest неизменён. Подпись создаёт кандидат **для** последующей аппаратной проверки; не утверждать, что upgrade acceptance уже пройдена до сборки кандидата.

Начать с read-only сверки существующего HP checkout, без checkout/reset/clean/rebase:

```bash
cd /opt/gallery-fork
git status --short
git branch --show-current
git rev-parse HEAD
sed -n 's/^version: //p' mobile/pubspec.yaml
```

Далее пользователь отдельно выбирает reviewed clean source и разрешает HP build. Для37 ожидаются branch `codex/issue17-smart-timeline`, version5.7.3+37; для промежуточного35→36 — ветка36/PR21. Ни code SHA выше, ни новый documentation HEAD сейчас не объявлены ready. Выполнить полный read-only preflight из release handoff; `require_live_photo_ci.py` ожидаемо остановится при pending/failure/нет exact-source gates. Не обходить его.

После закрытия gates и отдельного разрешения сборки (команды **не запускались**):

```bash
# release_sha — утверждённый полный SHA; release_build=37 после проверки pubspec.
release_output="/tmp/foto-build-$release_build-$release_sha"
test ! -e "$release_output"
bash scripts/release/server_build.sh "$release_sha" "$release_output"
```

После **отдельного разрешения подписи оригинальным существующим ключом**, clean branch и baseline36:

```bash
release_branch=codex/issue17-smart-timeline
installed_build=36
release_build=37
python3 scripts/release/android_release.py preflight \
  --repository /opt/gallery-fork --expected-head "$release_sha" --expected-branch "$release_branch" \
  --installed-build-number "$installed_build" --build-number "$release_build"
python3 scripts/release/android_release.py build \
  --repository /opt/gallery-fork --expected-head "$release_sha" --expected-branch "$release_branch" \
  --installed-build-number "$installed_build" --build-number "$release_build"
python3 scripts/release/android_release.py postflight \
  --repository /opt/gallery-fork --expected-head "$release_sha" --expected-branch "$release_branch" \
  --installed-build-number "$installed_build" --build-number "$release_build"
```

Не создавать/копировать/печатать keystore, не выполнять uninstall/clear-data при mismatch. Проверить35→36 и36→37 отдельно, package/certificate/versionCode/3ABIs, сохранить output SHA256/receipt. Docker build/export не означает permission заменить контейнеры. HP Linux не собирает iOS; macOS unsigned procedure и SideStore `--check-only` отдельно. `prepare_sidestore.py` default делает ad-hoc signing — не запускать по умолчанию.

## 7. Проверки, доказательства и ограничения среды

Локально: `python3 -m unittest discover -s mobile/scripts/tests -v`128PASS; `... -s scripts/release/tests -v`574total=557PASS/17SKIP; `... -s tools/foto-automation/tests -p '*scope.py' -v`22PASS.17skip:15 opt-in isolated Docker cases, JDK17 unavailable, readonly-publication fixture under root. Два Docker случая выполнялись отдельно исторически; это не новый общий PASS и не HP. Build diagnostics7PASS, annotation4PASS, detector4PASS. YAML/actionlint PASS (старая local actionlint не знаетmacOS26 label; expression errors исправлены, workflow принят GitHub).

Локального Flutter SDK нет; download ограничен policy. Не обходить ограничения. Flutter runs — hosted pinned SDK. Raw Actions logs/Azure artifact downloads недоступны; job/step metadata и check annotations доступны. Не публиковать short-lived signed artifact URLs/tokens. Analyzer/formatter/Flutter/native/API/Android bounded diagnostics уже добавлены; точный pinned formatter patch предпочтительнее отличающегося WASM formatter. Без доступногоstderr не придумывать причину.

Для воспроизведения C9 на разрешённом buildhost с Flutter (синтетические temp fixtures, без пользовательских фото):

```bash
mise //mobile:install:ci
mise //mobile:codegen
cd mobile
flutter test --no-pub --concurrency=1 \
  test/presentation/widgets/images/remote_image_provider_http_test.dart \
  test/presentation/widgets/timeline/offline_timeline_restart_test.dart \
  test/domain/services/sync_stream_service_test.dart
```

[Samsung/iPhone procedure](2026-11-04-build37-device-acceptance.md): все8 `selected→native-ready→play-request-accepted→position-advanced` с реальным движением/max1player; INFO app-log export и синтетическое видео; profile UI/raster p50/p95/p99/jank8.33ms; H3 matched Google density; themes/viewport/IME/trash/stack/places; C9 offline. Все H1–H8 **BLOCKED: device acceptance pending**.

Older unsigned iOS evidence только для своих SHA: Build37`1ad191b06` [run41791145259/job126444575440](https://github.com/docice545/gallery/actions/runs/41791145259/job/126444575440), IPA SHA256`0d111a03b83ce8f3c5a6affa507cf947946442f3c7037717a0a9948463d84252`; Build36`73c95a212` [run41795536579/job126458634497](https://github.com/docice545/gallery/actions/runs/41795536579/job/126458634497), IPA SHA256`3ae56458efa9c243d3619940a72fe4f97bf70884ea36dfb848fe8be165f274f2`. ZIP artifact hash не равен IPA hash. Это не текущие final artifacts.

## 8. Порядок следующей сессии

1. Прочитать этот handoff, весь BUILD37_CHECKLIST и применимые AGENTS/production-stack/cloud skills. Проверить dirty files и published PR heads. Не начинать auditA заново.
2. Получить **полные актуальные** #17/#18/PR16/PR20/PR21 через GitHub; сохранить icon approval/единственного исполнителя/разрешение reviewable Backend и ограничения.
3. Проверить продолжающиеся code-SHA runs из таблицы. Pending/fail-fast cancelled — выполнить; infra bootstrap rerun только после завершения общего run, с сохранением failed evidence. Не ретраить product smoke/rating радиPASS.
4. Для нового reviewed documentation/source HEAD запустить обычный push без skip-ci (если изменений кода не требуется, допустим отдельный обычный `ci:` checkpoint commit без amend/force). Дождаться всех exact-source gates; старые PASS автоматически не переносить.
5. Завершить только подтверждённые программные/CI проблемы, обновляя ту же матрицу. Затем HP/устройства по отдельным разрешениям. Не завершать большой Build37 одним C9 или одним редактором.

A выполнен; B/C/D частично. **Ни эта передача, ни зелёный отдельный job не снимают production NO-GO.**

## 9. Полный снимок GitHub CI jobs

Ниже статус **на время снимка**, а не обещание завершения. Сырые отфильтрованные metadata: [`2026-11-04-build37-final-checkpoint-handoff-ci.json`](2026-11-04-build37-final-checkpoint-handoff-ci.json). SUCCESS — только completed/success; QUEUED/IN_PROGRESS/PENDING/CANCELLED/SKIPPED не PASS. Trusted signing/publishing workflows намеренно SKIPPED. Jobs с названием Docker Success являются агрегаторами; реальную компиляцию подтверждает отдельный PR Docker compilation. Full Test может содержать отменённого fail-fast соседа.

### build37: `b01961b7d53f3a42293f1dfaea4d0578f77558f4`

| Workflow / event | Job | Статус | Последний активный/ошибочный шаг |
|---|---|---|---|
| [PR Conventional Commit](https://github.com/docice545/gallery/actions/runs/41816587471) / pull_request | [Validate PR Title (conventional commit) / validate-pr-title](https://github.com/docice545/gallery/actions/runs/41816587471/job/126528755040) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41816263048) / pull_request | [pre-job](https://github.com/docice545/gallery/actions/runs/41816263048/job/126527741618) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41816263048) / pull_request | [Live Photo timeline non-regression](https://github.com/docice545/gallery/actions/runs/41816263048/job/126527765673) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41816263048) / pull_request | [Release artifact and provenance checks](https://github.com/docice545/gallery/actions/runs/41816263048/job/126528300552) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41816263048) / pull_request | [Unsigned universal Android (no device acceptance)](https://github.com/docice545/gallery/actions/runs/41816263048/job/126528301217) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41816263048) / pull_request | [Flutter tests and coverage](https://github.com/docice545/gallery/actions/runs/41816263048/job/126528302476) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41816263048) / pull_request | [Live Photo native decoded motion](https://github.com/docice545/gallery/actions/runs/41816263048/job/126529685083) | IN_PROGRESS | Actual ExoPlayer, authenticated synthetic media and decoded position |
| [Zizmor](https://github.com/docice545/gallery/actions/runs/41816263614) / pull_request | [Zizmor / zizmor](https://github.com/docice545/gallery/actions/runs/41816263614/job/126527660912) | SUCCESS | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41816263641) / pull_request | [Docker Build & Push Server Success](https://github.com/docice545/gallery/actions/runs/41816263641/job/126529236618) | SUCCESS | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41816263641) / pull_request | [Docker Build & Push ML Success](https://github.com/docice545/gallery/actions/runs/41816263641/job/126529237530) | SUCCESS | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41816263641) / pull_request | [Build and Push ML](https://github.com/docice545/gallery/actions/runs/41816263641/job/126529239353) | SKIPPED | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41816263641) / pull_request | [pre-job](https://github.com/docice545/gallery/actions/runs/41816263641/job/126529286907) | SKIPPED | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41816263641) / pull_request | [Re-Tag Server](https://github.com/docice545/gallery/actions/runs/41816263641/job/126529291637) | SKIPPED | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41816263641) / pull_request | [Re-Tag ML](https://github.com/docice545/gallery/actions/runs/41816263641/job/126529297854) | SKIPPED | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41816263641) / pull_request | [Build and Push Server](https://github.com/docice545/gallery/actions/runs/41816263641/job/126529298079) | SKIPPED | — |
| [Docs build](https://github.com/docice545/gallery/actions/runs/41816263342) / pull_request | [pre-job](https://github.com/docice545/gallery/actions/runs/41816263342/job/126527663093) | SUCCESS | — |
| [Docs build](https://github.com/docice545/gallery/actions/runs/41816263342) / pull_request | [Docs Build](https://github.com/docice545/gallery/actions/runs/41816263342/job/126531551615) | SKIPPED | — |
| [PR Docker compilation (no publishing)](https://github.com/docice545/gallery/actions/runs/41816263114) / pull_request | [PR Docker build (machine-learning)](https://github.com/docice545/gallery/actions/runs/41816263114/job/126528163931) | SUCCESS | — |
| [PR Docker compilation (no publishing)](https://github.com/docice545/gallery/actions/runs/41816263114) / pull_request | [PR Docker build (server)](https://github.com/docice545/gallery/actions/runs/41816263114/job/126528164062) | SUCCESS | — |
| [PR Release Candidate](https://github.com/docice545/gallery/actions/runs/41816263189) / pull_request | [Build RC image](https://github.com/docice545/gallery/actions/runs/41816263189/job/126527660163) | SKIPPED | — |
| [PR Release Candidate](https://github.com/docice545/gallery/actions/runs/41816263189) / pull_request | [Update RC comment](https://github.com/docice545/gallery/actions/runs/41816263189/job/126527664584) | SKIPPED | — |
| [PR Release Candidate](https://github.com/docice545/gallery/actions/runs/41816263189) / pull_request | [Resolve RC number](https://github.com/docice545/gallery/actions/runs/41816263189/job/126527716913) | SKIPPED | — |
| [Gallery Build Mobile](https://github.com/docice545/gallery/actions/runs/41816263297) / pull_request | [Regenerate iOS CocoaPods lock for review](https://github.com/docice545/gallery/actions/runs/41816263297/job/126527661722) | SKIPPED | — |
| [Gallery Build Mobile](https://github.com/docice545/gallery/actions/runs/41816263297) / pull_request | [Verify or explicitly release iOS](https://github.com/docice545/gallery/actions/runs/41816263297/job/126527703922) | SKIPPED | — |
| [Gallery Build Mobile](https://github.com/docice545/gallery/actions/runs/41816263297) / pull_request | [Android media pilot (no publishing)](https://github.com/docice545/gallery/actions/runs/41816263297/job/126527722986) | SKIPPED | — |
| [Gallery Build Mobile](https://github.com/docice545/gallery/actions/runs/41816263297) / pull_request | [Build and sign Android](https://github.com/docice545/gallery/actions/runs/41816263297/job/126527817257) | SKIPPED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [SQL Schema Checks](https://github.com/docice545/gallery/actions/runs/41816263251/job/126528091192) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [OpenAPI Clients](https://github.com/docice545/gallery/actions/runs/41816263251/job/126528091414) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [pre-job](https://github.com/docice545/gallery/actions/runs/41816263251/job/126528091687) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [ShellCheck](https://github.com/docice545/gallery/actions/runs/41816263251/job/126528091866) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [Upstream Rebase Tooling](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531819675) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [Unit Test CLI (Windows)](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531819714) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [End-to-End Lint](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531819730) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [Unit Test Mobile](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820089) | IN_PROGRESS | Run tests |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [Test Web](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820113) | IN_PROGRESS | Run ci-unit |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [End-to-End Tests (Server & CLI) (ubuntu-24.04-arm)](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820319) | FAILURE | Start Docker Compose |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [Unit Test ML](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820374) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [Test Branding](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820408) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [Unit Test CLI](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820411) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [Test i18n](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820427) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [End-to-End Tests (Server & CLI) (ubuntu-latest)](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820478) | CANCELLED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [Unit Test ML Training](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820599) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [Lint Web](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820698) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [Test & Lint Server](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820735) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [.github Files Formatting](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531820958) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [End-to-End Tests (Web) (ubuntu-latest)](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531822969) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816263251) / pull_request | [Medium Tests (Server)](https://github.com/docice545/gallery/actions/runs/41816263251/job/126531824737) | QUEUED | — |
| [Migration Order](https://github.com/docice545/gallery/actions/runs/41816263089) / pull_request | [Verify migration ORDER](https://github.com/docice545/gallery/actions/runs/41816263089/job/126527897860) | SUCCESS | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41816263386) / pull_request | [Android durable thumbnail cache regression tests](https://github.com/docice545/gallery/actions/runs/41816263386/job/126529571050) | SUCCESS | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41816263386) / pull_request | [API contract and compatibility regressions](https://github.com/docice545/gallery/actions/runs/41816263386/job/126529571267) | SUCCESS | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41816263386) / pull_request | [Stock Android 5.9.0 emulator E2E](https://github.com/docice545/gallery/actions/runs/41816263386/job/126529571347) | QUEUED | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41816263386) / pull_request | [iOS source and simulator contract checks](https://github.com/docice545/gallery/actions/runs/41816263386/job/126529571450) | SUCCESS | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41816263386) / pull_request | [FOTO Build 22 offline timeline emulator E2E](https://github.com/docice545/gallery/actions/runs/41816263386/job/126529572468) | IN_PROGRESS | Build final debug APK for emulator evidence |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41816263386) / pull_request | [Stock Android 5.8.0 emulator E2E](https://github.com/docice545/gallery/actions/runs/41816263386/job/126529605315) | SUCCESS | — |
| [Static Code Analysis](https://github.com/docice545/gallery/actions/runs/41816263051) / pull_request | [pre-job](https://github.com/docice545/gallery/actions/runs/41816263051/job/126527661106) | SUCCESS | — |
| [Static Code Analysis](https://github.com/docice545/gallery/actions/runs/41816263051) / pull_request | [Targeted backend ACK contracts](https://github.com/docice545/gallery/actions/runs/41816263051/job/126527668302) | SKIPPED | — |
| [Static Code Analysis](https://github.com/docice545/gallery/actions/runs/41816263051) / pull_request | [Run Dart Code Analysis](https://github.com/docice545/gallery/actions/runs/41816263051/job/126527767262) | SUCCESS | — |
| [PR Conventional Commit](https://github.com/docice545/gallery/actions/runs/41816263629) / pull_request | [Validate PR Title (conventional commit) / validate-pr-title](https://github.com/docice545/gallery/actions/runs/41816263629/job/126527661024) | SUCCESS | — |
| [Build 37 smart Timeline regression gate](https://github.com/docice545/gallery/actions/runs/41816263055) / pull_request | [Modes, density, date overlay and Live Photo contracts](https://github.com/docice545/gallery/actions/runs/41816263055/job/126527687220) | SUCCESS | — |
| [Build 37 smart Timeline regression gate](https://github.com/docice545/gallery/actions/runs/41816263055) / pull_request | [Explicit Places screenshot review (no release)](https://github.com/docice545/gallery/actions/runs/41816263055/job/126527714853) | SKIPPED | — |
| [Build 37 smart Timeline regression gate](https://github.com/docice545/gallery/actions/runs/41816263055) / pull_request | [Explicit editor screenshot review (no release)](https://github.com/docice545/gallery/actions/runs/41816263055/job/126527726506) | SKIPPED | — |
| [Build 37 smart Timeline regression gate](https://github.com/docice545/gallery/actions/runs/41816263055) / pull_request | [Native decoded motion (emulator, Samsung still required)](https://github.com/docice545/gallery/actions/runs/41816263055/job/126531381907) | SUCCESS | — |
| [Pull Request Labeler](https://github.com/docice545/gallery/actions/runs/41816260723) / pull_request_target | [labeler](https://github.com/docice545/gallery/actions/runs/41816260723/job/126527663245) | SUCCESS | — |
| [PR Label Validation](https://github.com/docice545/gallery/actions/runs/41816260523) / pull_request_target | [validate-release-label](https://github.com/docice545/gallery/actions/runs/41816260523/job/126527730115) | SUCCESS | — |
| [Static Code Analysis](https://github.com/docice545/gallery/actions/runs/41816254318) / push | [Targeted backend ACK contracts](https://github.com/docice545/gallery/actions/runs/41816254318/job/126527637423) | SKIPPED | — |
| [Static Code Analysis](https://github.com/docice545/gallery/actions/runs/41816254318) / push | [pre-job](https://github.com/docice545/gallery/actions/runs/41816254318/job/126527638955) | SUCCESS | — |
| [Static Code Analysis](https://github.com/docice545/gallery/actions/runs/41816254318) / push | [Run Dart Code Analysis](https://github.com/docice545/gallery/actions/runs/41816254318/job/126531698385) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41816253697) / push | [Live Photo timeline non-regression](https://github.com/docice545/gallery/actions/runs/41816253697/job/126527935734) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41816253697) / push | [pre-job](https://github.com/docice545/gallery/actions/runs/41816253697/job/126527936474) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41816253697) / push | [Release artifact and provenance checks](https://github.com/docice545/gallery/actions/runs/41816253697/job/126529717609) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41816253697) / push | [Flutter tests and coverage](https://github.com/docice545/gallery/actions/runs/41816253697/job/126529718206) | IN_PROGRESS | Run Flutter tests with coverage |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41816253697) / push | [Unsigned universal Android (no device acceptance)](https://github.com/docice545/gallery/actions/runs/41816253697/job/126529719751) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41816253697) / push | [Live Photo native decoded motion](https://github.com/docice545/gallery/actions/runs/41816253697/job/126530082534) | IN_PROGRESS | Actual ExoPlayer, authenticated synthetic media and decoded position |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [SQL Schema Checks](https://github.com/docice545/gallery/actions/runs/41816253607/job/126527971725) | FAILURE | Initialize containers |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [pre-job](https://github.com/docice545/gallery/actions/runs/41816253607/job/126527971781) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [OpenAPI Clients](https://github.com/docice545/gallery/actions/runs/41816253607/job/126527972469) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [ShellCheck](https://github.com/docice545/gallery/actions/runs/41816253607/job/126527973161) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [Unit Test ML](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533063191) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [Upstream Rebase Tooling](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533063409) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [.github Files Formatting](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533063440) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [Test Web](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533063501) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [Test i18n](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533063529) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [End-to-End Tests (Server & CLI) (ubuntu-latest)](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533063537) | CANCELLED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [Lint Web](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533063546) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [Test & Lint Server](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533063547) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [Unit Test Mobile](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533063595) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [Test Branding](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533063842) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [Unit Test CLI](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533064013) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [Medium Tests (Server)](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533064454) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [End-to-End Tests (Web) (ubuntu-latest)](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533064461) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [Unit Test ML Training](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533064612) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [End-to-End Lint](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533064667) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [Unit Test CLI (Windows)](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533064697) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41816253607) / push | [End-to-End Tests (Server & CLI) (ubuntu-24.04-arm)](https://github.com/docice545/gallery/actions/runs/41816253607/job/126533064725) | FAILURE | Start Docker Compose |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41816253640) / push | [iOS source and simulator contract checks](https://github.com/docice545/gallery/actions/runs/41816253640/job/126529541246) | SUCCESS | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41816253640) / push | [Stock Android 5.8.0 emulator E2E](https://github.com/docice545/gallery/actions/runs/41816253640/job/126529541355) | SUCCESS | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41816253640) / push | [API contract and compatibility regressions](https://github.com/docice545/gallery/actions/runs/41816253640/job/126529541611) | SUCCESS | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41816253640) / push | [FOTO Build 22 offline timeline emulator E2E](https://github.com/docice545/gallery/actions/runs/41816253640/job/126529541708) | IN_PROGRESS | Build and start disposable FOTO backend |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41816253640) / push | [Android durable thumbnail cache regression tests](https://github.com/docice545/gallery/actions/runs/41816253640/job/126529545350) | IN_PROGRESS | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41816253640) / push | [Stock Android 5.9.0 emulator E2E](https://github.com/docice545/gallery/actions/runs/41816253640/job/126529665174) | QUEUED | — |

### backend: `451b475c25fb66aaacabfff73fc6b5799b7c39a4`

| Workflow / event | Job | Статус | Последний активный/ошибочный шаг |
|---|---|---|---|
| [PR Conventional Commit](https://github.com/docice545/gallery/actions/runs/41817673315) / pull_request | [Validate PR Title (conventional commit) / validate-pr-title](https://github.com/docice545/gallery/actions/runs/41817673315/job/126532484957) | SUCCESS | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41817673702) / pull_request | [Re-Tag Server](https://github.com/docice545/gallery/actions/runs/41817673702/job/126532878973) | SKIPPED | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41817673702) / pull_request | [Build and Push ML](https://github.com/docice545/gallery/actions/runs/41817673702/job/126532879358) | SKIPPED | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41817673702) / pull_request | [Docker Build & Push Server Success](https://github.com/docice545/gallery/actions/runs/41817673702/job/126532879926) | SUCCESS | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41817673702) / pull_request | [Docker Build & Push ML Success](https://github.com/docice545/gallery/actions/runs/41817673702/job/126532880526) | SUCCESS | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41817673702) / pull_request | [pre-job](https://github.com/docice545/gallery/actions/runs/41817673702/job/126532929686) | SKIPPED | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41817673702) / pull_request | [Build and Push Server](https://github.com/docice545/gallery/actions/runs/41817673702/job/126532932380) | SKIPPED | — |
| [Docker](https://github.com/docice545/gallery/actions/runs/41817673702) / pull_request | [Re-Tag ML](https://github.com/docice545/gallery/actions/runs/41817673702/job/126532940344) | SKIPPED | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41817672479) / pull_request | [iOS source and simulator contract checks](https://github.com/docice545/gallery/actions/runs/41817672479/job/126534343118) | IN_PROGRESS | Build unsigned iOS simulator app |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41817672479) / pull_request | [Stock Android 5.9.0 emulator E2E](https://github.com/docice545/gallery/actions/runs/41817672479/job/126534343529) | QUEUED | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41817672479) / pull_request | [API contract and compatibility regressions](https://github.com/docice545/gallery/actions/runs/41817672479/job/126534343766) | SUCCESS | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41817672479) / pull_request | [FOTO Build 22 offline timeline emulator E2E](https://github.com/docice545/gallery/actions/runs/41817672479/job/126534344411) | IN_PROGRESS | Build final debug APK for emulator evidence |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41817672479) / pull_request | [Stock Android 5.8.0 emulator E2E](https://github.com/docice545/gallery/actions/runs/41817672479/job/126534347032) | IN_PROGRESS | Reclaim unused hosted toolchains before backend and stock emulator |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41817672479) / pull_request | [Android durable thumbnail cache regression tests](https://github.com/docice545/gallery/actions/runs/41817672479/job/126534459840) | QUEUED | — |
| [Zizmor](https://github.com/docice545/gallery/actions/runs/41817673061) / pull_request | [Zizmor / zizmor](https://github.com/docice545/gallery/actions/runs/41817673061/job/126532486248) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41817672534) / pull_request | [Live Photo timeline non-regression](https://github.com/docice545/gallery/actions/runs/41817672534/job/126532488209) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41817672534) / pull_request | [pre-job](https://github.com/docice545/gallery/actions/runs/41817672534/job/126532490402) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41817672534) / pull_request | [Flutter tests and coverage](https://github.com/docice545/gallery/actions/runs/41817672534/job/126533006265) | IN_PROGRESS | Perform codegen |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41817672534) / pull_request | [Release artifact and provenance checks](https://github.com/docice545/gallery/actions/runs/41817672534/job/126533006536) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41817672534) / pull_request | [Unsigned universal Android (no device acceptance)](https://github.com/docice545/gallery/actions/runs/41817672534/job/126533010788) | IN_PROGRESS | Run android-actions/setup-android@40fd30fb8d7440372e1316f5d1809ec01dcd3699 |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41817672534) / pull_request | [Live Photo native decoded motion](https://github.com/docice545/gallery/actions/runs/41817672534/job/126534351647) | QUEUED | — |
| [Docs build](https://github.com/docice545/gallery/actions/runs/41817672426) / pull_request | [pre-job](https://github.com/docice545/gallery/actions/runs/41817672426/job/126532482732) | SUCCESS | — |
| [Docs build](https://github.com/docice545/gallery/actions/runs/41817672426) / pull_request | [Docs Build](https://github.com/docice545/gallery/actions/runs/41817672426/job/126533098254) | SKIPPED | — |
| [Migration Order](https://github.com/docice545/gallery/actions/runs/41817672431) / pull_request | [Verify migration ORDER](https://github.com/docice545/gallery/actions/runs/41817672431/job/126532482751) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41817672516) / pull_request | [SQL Schema Checks](https://github.com/docice545/gallery/actions/runs/41817672516/job/126534589246) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41817672516) / pull_request | [OpenAPI Clients](https://github.com/docice545/gallery/actions/runs/41817672516/job/126534589253) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41817672516) / pull_request | [ShellCheck](https://github.com/docice545/gallery/actions/runs/41817672516/job/126534589261) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41817672516) / pull_request | [pre-job](https://github.com/docice545/gallery/actions/runs/41817672516/job/126534592481) | QUEUED | — |
| [PR Release Candidate](https://github.com/docice545/gallery/actions/runs/41817672430) / pull_request | [Resolve RC number](https://github.com/docice545/gallery/actions/runs/41817672430/job/126532485922) | SKIPPED | — |
| [PR Release Candidate](https://github.com/docice545/gallery/actions/runs/41817672430) / pull_request | [Update RC comment](https://github.com/docice545/gallery/actions/runs/41817672430/job/126532486323) | SKIPPED | — |
| [PR Release Candidate](https://github.com/docice545/gallery/actions/runs/41817672430) / pull_request | [Build RC image](https://github.com/docice545/gallery/actions/runs/41817672430/job/126532501118) | SKIPPED | — |
| [Gallery Build Mobile](https://github.com/docice545/gallery/actions/runs/41817672533) / pull_request | [Regenerate iOS CocoaPods lock for review](https://github.com/docice545/gallery/actions/runs/41817672533/job/126532484003) | SKIPPED | — |
| [Gallery Build Mobile](https://github.com/docice545/gallery/actions/runs/41817672533) / pull_request | [Build and sign Android](https://github.com/docice545/gallery/actions/runs/41817672533/job/126532525025) | SKIPPED | — |
| [Gallery Build Mobile](https://github.com/docice545/gallery/actions/runs/41817672533) / pull_request | [Verify or explicitly release iOS](https://github.com/docice545/gallery/actions/runs/41817672533/job/126532542964) | SKIPPED | — |
| [Gallery Build Mobile](https://github.com/docice545/gallery/actions/runs/41817672533) / pull_request | [Android media pilot (no publishing)](https://github.com/docice545/gallery/actions/runs/41817672533/job/126532547348) | SKIPPED | — |
| [Static Code Analysis](https://github.com/docice545/gallery/actions/runs/41817672412) / pull_request | [pre-job](https://github.com/docice545/gallery/actions/runs/41817672412/job/126532997620) | SUCCESS | — |
| [Static Code Analysis](https://github.com/docice545/gallery/actions/runs/41817672412) / pull_request | [Targeted backend ACK contracts](https://github.com/docice545/gallery/actions/runs/41817672412/job/126533002452) | SKIPPED | — |
| [Static Code Analysis](https://github.com/docice545/gallery/actions/runs/41817672412) / pull_request | [Run Dart Code Analysis](https://github.com/docice545/gallery/actions/runs/41817672412/job/126535096142) | SUCCESS | — |
| [PR Docker compilation (no publishing)](https://github.com/docice545/gallery/actions/runs/41817672429) / pull_request | [PR Docker build (server)](https://github.com/docice545/gallery/actions/runs/41817672429/job/126532487441) | SUCCESS | — |
| [PR Docker compilation (no publishing)](https://github.com/docice545/gallery/actions/runs/41817672429) / pull_request | [PR Docker build (machine-learning)](https://github.com/docice545/gallery/actions/runs/41817672429/job/126532489702) | SUCCESS | — |
| [PR Label Validation](https://github.com/docice545/gallery/actions/runs/41817669170) / pull_request_target | [validate-release-label](https://github.com/docice545/gallery/actions/runs/41817669170/job/126532476311) | SUCCESS | — |
| [Pull Request Labeler](https://github.com/docice545/gallery/actions/runs/41817669261) / pull_request_target | [labeler](https://github.com/docice545/gallery/actions/runs/41817669261/job/126532477295) | SUCCESS | — |
| [Static Code Analysis](https://github.com/docice545/gallery/actions/runs/41817664144) / push | [pre-job](https://github.com/docice545/gallery/actions/runs/41817664144/job/126532453273) | SUCCESS | — |
| [Static Code Analysis](https://github.com/docice545/gallery/actions/runs/41817664144) / push | [Targeted backend ACK contracts](https://github.com/docice545/gallery/actions/runs/41817664144/job/126532455281) | SKIPPED | — |
| [Static Code Analysis](https://github.com/docice545/gallery/actions/runs/41817664144) / push | [Run Dart Code Analysis](https://github.com/docice545/gallery/actions/runs/41817664144/job/126532883950) | SUCCESS | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41817664042) / push | [Android durable thumbnail cache regression tests](https://github.com/docice545/gallery/actions/runs/41817664042/job/126534313349) | QUEUED | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41817664042) / push | [FOTO Build 22 offline timeline emulator E2E](https://github.com/docice545/gallery/actions/runs/41817664042/job/126534313459) | IN_PROGRESS | Install mobile dependencies and generated clients |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41817664042) / push | [Stock Android 5.8.0 emulator E2E](https://github.com/docice545/gallery/actions/runs/41817664042/job/126534313477) | IN_PROGRESS | Build and start disposable FOTO backend |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41817664042) / push | [iOS source and simulator contract checks](https://github.com/docice545/gallery/actions/runs/41817664042/job/126534313545) | FAILURE | Run immich-app/devtools/actions/use-mise@06a9ef925332c91be647d6256642b86b398592c8 |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41817664042) / push | [API contract and compatibility regressions](https://github.com/docice545/gallery/actions/runs/41817664042/job/126534313796) | QUEUED | — |
| [Original Noodle Gallery compatibility](https://github.com/docice545/gallery/actions/runs/41817664042) / push | [Stock Android 5.9.0 emulator E2E](https://github.com/docice545/gallery/actions/runs/41817664042/job/126534313850) | QUEUED | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41817664335) / push | [SQL Schema Checks](https://github.com/docice545/gallery/actions/runs/41817664335/job/126534430485) | SUCCESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41817664335) / push | [ShellCheck](https://github.com/docice545/gallery/actions/runs/41817664335/job/126534430586) | IN_PROGRESS | — |
| [Test](https://github.com/docice545/gallery/actions/runs/41817664335) / push | [OpenAPI Clients](https://github.com/docice545/gallery/actions/runs/41817664335/job/126534431066) | IN_PROGRESS | Install server dependencies |
| [Test](https://github.com/docice545/gallery/actions/runs/41817664335) / push | [pre-job](https://github.com/docice545/gallery/actions/runs/41817664335/job/126534433977) | QUEUED | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41817664605) / push | [pre-job](https://github.com/docice545/gallery/actions/runs/41817664605/job/126532970135) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41817664605) / push | [Live Photo timeline non-regression](https://github.com/docice545/gallery/actions/runs/41817664605/job/126532970825) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41817664605) / push | [Unsigned universal Android (no device acceptance)](https://github.com/docice545/gallery/actions/runs/41817664605/job/126533773218) | IN_PROGRESS | Build unsigned universal APK |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41817664605) / push | [Release artifact and provenance checks](https://github.com/docice545/gallery/actions/runs/41817664605/job/126533773297) | SUCCESS | — |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41817664605) / push | [Flutter tests and coverage](https://github.com/docice545/gallery/actions/runs/41817664605/job/126533774520) | IN_PROGRESS | Run Flutter tests with coverage |
| [Build Mobile](https://github.com/docice545/gallery/actions/runs/41817664605) / push | [Live Photo native decoded motion](https://github.com/docice545/gallery/actions/runs/41817664605/job/126535377438) | IN_PROGRESS | Locked native media code generation |
