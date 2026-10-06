# iOS: deployment targets и unsigned build-only lane

Этот документ описывает реализованные пункты 5/6 существующего
[`iOS readiness audit`](../2026-10-05-ios-readiness-design.md). Это не повторный аудит и
не подтверждение подписанной установки. Cloud execution environment — Linux: Apple frameworks,
Xcode archive и iPhone здесь не компилировались/не проверялись.

## Поддерживаемые версии

| Target          | Минимальная iOS | Политика                                                                                                                                                                                              |
| --------------- | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Runner          | 15.0            | Сохранена поддержка основного приложения, общий UI/серверные функции/PhotoKit. Нативные функции, уже gated `#available(iOS 16, *)`, остаются gated                                                    |
| ShareExtension  | 16.0            | Сохранён существующий support floor extension; на iOS 15 extension недоступен. Его upstream handler допускает более старую ОС, но расширять support без native/device проверки эта задача не пытается |
| WidgetExtension | 17.0            | Требуется существующими AppIntentConfiguration/AppIntentTimelineProvider, `.containerBackground` и `.contentMarginsDisabled`; widgets недоступны на iOS 15/16                                         |

Debug/Profile/Release сохраняют указанные значения во всех трёх targets. Main application не
поднято до 16/17. Podfile явно задаёт ShareExtension iOS 16; post-install больше не понижает
dependencies с более высоким собственным floor до 15. `App.framework` содержит minimum iOS 15.
Library versions в `Podfile.lock` сохранены; изменился checksum изменённого Podfile. CocoaPods
tool закреплён на уже указанной в lock версии 1.17.0. IDs, target names, App Groups и entitlements
не переименованы.

Runner scheme продолжает собирать и встраивать обе extensions. Availability встроенных
extensions на младшей ОС, установка/обновление iOS 15 и итоговая validation archive остаются
`NEEDS_MAC_VALIDATION` / `NEEDS_PHYSICAL_IPHONE_VALIDATION`; одних значений project file
недостаточно, чтобы заявить signed install на всех трёх floors.

## Один существующий workflow

Используется `.github/workflows/gallery-build-mobile.yml`, без второго дублирующего workflow.
Для unsigned проверки:

```bash
# После push нужного SHA в work: version должен быть пустым.
gh workflow run gallery-build-mobile.yml --ref work \
  -f build_target=ios -f environment=development -f version=''

# Зафиксировать run ID/коммит, затем дождаться результата и загрузить archive.
gh run list --workflow gallery-build-mobile.yml --branch work --limit 5
gh run watch <RUN_ID> --exit-status
gh run download <RUN_ID> --name ios-unsigned-archive --dir ./ios-unsigned-archive
```

Эквивалентный API dispatch — **POST**
`/repos/docice545/gallery/actions/workflows/gallery-build-mobile.yml/dispatches` с телом:

```json
{
  "inputs": {
    "build_target": "ios",
    "environment": "development",
    "version": ""
  },
  "ref": "work"
}
```

Перед dispatch следует проверить точный SHA `origin/work`. Ответ 204 означает только приём
запроса; успешная compilation подтверждается последующим run, его `head_sha`, logs и artifact.
Если Actions API возвращает 403/404, это access/registration gate, а не результат Xcode build.
Успешное чтение repository contents и repository role `admin` сами по себе не доказывают
разрешение integration token на Actions endpoints. Не менять main, настройки Actions или
credentials лишь для обхода отказа; сохранить точный HTTP status и native gate в отчёте.

Для пустого `version` ASC key/certificate/keychain steps не выполняются; signing/store secrets в
workflow_call стали optional, чтобы iOS-only reusable call не требовал Android credentials. `build_target=ios` исключает Android job. `version != ''` остаётся
отдельным явным signing/export/TestFlight gate. Старый `build-mobile.yml` также получил отдельный
optional `ios_release=false`: обычные PR/main builds не получают iOS signing credentials только
из-за прежнего общего Android `DEPLOY` флага. Android signing steps/configuration не менялись.

## Полный unsigned путь

`mobile/scripts/ios_build_only.sh`:

1. Проверяет macOS, наличие Xcode, совпадение Flutter pin в `mobile/mise.toml` и `pubspec.yaml`,
   а также реальную запущенную через mise версию Flutter 3.47.2. SDK mismatch — ошибка до codegen.
2. Использует существующий CocoaPods путь Flutter plugins. Выполняет pinned OpenAPI Dart
   generation, `flutter pub get --enforce-lockfile`, все Pigeon definitions (включая intentional
   Kotlin-only APIs), translations loader/keys, Drift migration/schema, build_runner и format
   generated router. Pigeon берётся из resolved package_config, без абсолютного машинного cache
   path и без `dart run` Flutter dependency-resolution проблемы.
3. Выполняет `bundle exec pod install --deployment`, без `pod update` и без изменения dependency
   resolutions. macOS environment должен предварительно установить проектные mise tools и
   Ruby/Gemfile dependencies; CI уже делает это существующими setup steps.
4. Удаляет только свой предыдущий `mobile/build/ios/archive/Runner.xcarchive`, чтобы stale archive
   не превратил отсутствие нового результата в успех.
5. Выполняет `flutter build ipa --release --no-codesign`. Здесь `ipa` — Flutter archive command;
   unsigned build не экспортирует installable signed IPA.
6. Требует настоящий archive, ровно один app bundle, plist и непустой executable для Runner,
   ShareExtension и WidgetExtension; проверяет compiled minimum versions, relative extension IDs и существующие fork bundle/App Group IDs из branding config.
   Отсутствующий/пустой artifact, неверный floor или несовместимый extension ID — ошибка.

Все Flutter/Dart commands выполняются через project mise. Root node/Java/OpenAPI pins уже
существуют и не обновлены. Lane не вызывает ASC, `sigh`, certificate import, signing, IPA export
или upload. `gha_build_only` Fastlane lane теперь вызывает тот же script и не требует credentials.

Основной artifact: `mobile/build/ios/archive/Runner.xcarchive`; upload step содержит
`if-no-files-found: error`. Signed release Fastlane paths явно заданы: archive там же, exported
IPA — `mobile/build/ios/ipa/gallery.ipa`. Прежний неподтверждённый `mobile/ios/Runner.ipa` устранён.

На подготовленном macOS checkout, после существующего branding overlay и установки mise/Gemfile:

```bash
cd mobile
bash scripts/ios_build_only.sh
```

`--prepare-only` предназначен для Xcode Cloud перед его configured native action;
`--skip-prepare` допустим только после той же полной подготовки. Обычный CI использует script
без параметров. Xcode Cloud больше не клонирует unpinned Flutter stable: устанавливает project
mise pins и вызывает полный `--prepare-only` путь. Signing/distribution Xcode Cloud action
настраивается отдельно и не получает автоматического разрешения этим script.

## Выполненные offline проверки

- `python3 -m unittest discover -s mobile/scripts/tests -v`: **23 passed**. Проверены реальные
  subprocess-команды script на stub tools, полный codegen order/locked install, version/OS gates,
  build failure propagation, отсутствие/stale archive, app/extension artifacts и identity/floors,
  независимые deployment targets, plist/entitlements всех targets и workflow credential gates.
- Ruff check/format для двух Python файлов: passed.
- `bash -n` для build-only script и Xcode Cloud post-clone: passed.
- YAML parse и conditions checked для обоих изменённых workflows.

Stub commands и fixture binaries намеренно проверяют orchestration/artifact failure semantics.
Они **не являются** Swift, CocoaPods, Flutter AOT, Xcode compile или signed-device проверкой.
Fastlane/Podfile Ruby source проверен статически; interpreter validation выполняется на macOS.

## Native gates

`NEEDS_MAC_VALIDATION`: выполнить существующий workflow на точном новом SHA, сохранить run URL,
Xcode/Flutter versions, полный build log; проверить compiled Runner + both extensions, full
codegen, Podfile.lock/SPM compatibility и unsigned archive contents. Build must fail if expected
artifact is absent. Не export/install unsigned artifact как release IPA.

`NEEDS_PHYSICAL_IPHONE_VALIDATION`: signed install/update на поддерживаемых floors, App Groups и
profiles всех targets; проверить, что iOS 15 Runner работает без Share/Widget, iOS 16 Share
появляется без Widget, iOS 17+ оба extensions доступны. Сохранение auth/session, PhotoKit rights,
paired resources, background lifecycle и общий UI проверяются acceptance plan основной iOS
implementation; unsigned compilation не заменяет эти испытания.

## Фактическая попытка GitHub Actions

После push CI/code commit `9034f4027d1eadbd4c5ac19ad668c9f173f7a96c` в `origin/work`
выполнен описанный выше POST dispatch с `build_target=ios`, `environment=development`,
пустым `version`. 2026-10-05 GitHub ответил **404 Not Found**, а не 204.
Workflow contents подтверждены через API в `main` и `work`; список зарегистрированных
Actions workflows возвращает `total_count=0`. API Actions permissions отвечает **403
Resource not accessible by integration**. Эти ответы не позволяют различить выключенные
fork Actions и недостаточные Actions permissions подключения; не утверждаем конкретную
непроверенную причину.

Run не создан: нет run ID/URL, Xcode log, unsigned archive или IPA artifact.
Это внешний Actions access/registration blocker, а не compile/signing failure.
Нужно проверить включение Actions во вкладке fork и разрешение **Actions: write**
у подключения, затем повторить credentials-free dispatch на актуальном `origin/work`.
Apple credentials для этой стадии не требуются. Native gate остаётся
`NEEDS_MAC_VALIDATION`; физические проверки отдельно `NEEDS_PHYSICAL_IPHONE_VALIDATION`.

## CocoaPods graph correction (2026-10-06)

Run `37411808876` reached CocoaPods deployment verification and stopped before
Xcode compilation. The tracked `mobile/ios/Podfile.lock` still described the older
mixed Flutter SwiftPM/CocoaPods graph: 19 SwiftPM-capable plugin pods were omitted.
The current lane disables Flutter SwiftPM, so all CocoaPods-capable plugins must
be present. Updating only `PODFILE CHECKSUM` was insufficient.

Only the CocoaPods lock needs native dependency regeneration for this failure.
`pubspec.lock` remains frozen; existing `Package.resolved` files are not this
failure's cause. Plugin registrant, `.flutter-plugins-dependencies`, `.symlinks`,
`Pods` and `Flutter/ephemeral` remain ignored generated files.

The explicit `--refresh-pods-lock` maintenance mode runs the same pinned Flutter
preparation, `bundle exec pod install` (not `pod update`), immediately followed by
`bundle exec pod install --deployment`, then exits without compilation/signing.
Normal and `--prepare-only` modes still install only with `--deployment`.

When macOS is unavailable locally, the existing workflow can perform this
maintenance with `refresh_ios_pods_lock=true`, `build_target=ios`, empty `version`.
It stages **only** `Podfile.lock` into a unique
`codex/ios-pods-lock-<run-id>` review branch. Review that commit, fast-forward it
into `work`, push, then run the normal unsigned build from the committed lock.
Only the explicit fork/dispatch maintenance job has `contents:write`; normal
build jobs keep `contents:read`. This mode does not make stale-lock builds pass:
it does not compile or produce an app archive.

Failed command output is retained in the ordinary Actions log; the final 160 lines
are also emitted as an escaped error annotation, preserving the original nonzero
exit status. This enables diagnosis through the API without weakening verification.
No paid signing, App Store Connect configuration, production or Takeout work is
part of this correction.
