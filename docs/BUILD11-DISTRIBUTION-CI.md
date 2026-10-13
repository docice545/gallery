# Сборка дистрибутива Build 11 из готовых CI-артефактов

Используется существующий workflow `.github/workflows/gallery-trash-release-proof.yml`.
Он не компилирует приложения, не использует production-ключи и не подключается к HP.
Исторические параметры Build 8/9 сохранены. Для Build 11 необходимо явно передать
`build11=true`, полный `source_commit` и четыре различных успешных run ID:
`backend_run`, `android_run`, `ios_run`, `rollback_run`, а также `rollback_source`.

Android и iOS должны иметь `head_sha`, равный `source_commit`. Backend image
должен содержать этот же application source. Для backend допускается только
tooling-only descendant HEAD: проверяются Git ancestry, неизменность всех
application/build inputs и точное соответствие `manifest.toolingCommit` workflow HEAD.
Workflow проверяет принадлежность `docice545/gallery`, тип workflow, успешный
результат, единственный доступный артефакт ожидаемого имени и ограниченный размер
до скачивания. Tooling-only HEAD упаковочного workflow также допустим только при неизменных
application/build inputs и когда исходный commit является его предком. Каждая ZIP скачивается один раз.

Артефакты проверяются инструментами Android SDK 36, unsigned IPA verifier и
потоковой проверкой Docker config/layers. APK должен иметь production package ID,
5.7.3 (11), корректный manifest и ровно один CI-сертификат. Такой APK нельзя
устанавливать поверх HP-signed production APK: требуется отдельная подпись
сохранённой production-идентичностью через готовый signing adapter после approval.
IPA остаётся неподписанным; установка выполняется существующим SideStore способом.

`build11_compatibility_receipt.py` использует существующий `artifact_image()` и
`IMAGE_PROBE`, читая реальные compiled guards и migrations в networkless read-only
контейнере. Он принимает только настоящий `build11-rollback-runtime.json`,
опубликованный successful backend workflow вместе с образом. Проверяются SHA-256
этого отчёта, exact source/image/archive и реальные результаты old-runtime HTTP,
Trash/Restore на новой схеме, отказ storage-policy deletion после rollback и
работающие API+microservices/thumbnail+preview. Отсутствие отчёта блокирует упаковку.

При различии Docker config ID и containerd manifest/index ID никакой произвольный
alias не допускается: полный descriptor graph исходного архива должен связывать
зафиксированный ID с exact config и ordered layer bytes. Исходный runtime report
не изменяется. Проверки повторяются в classic и containerd stores; итоговые
compatibility receipt bytes должны совпасть. Signed recovery-proof не создаётся,
не переиздаётся и не ослабляется этим процессом.

До публикации provisional package проходит реальный isolated clean install,
upgrade представительного Build 10, migration/data/queue preservation, full
managed/external disposable deletion и rollback с interruption/repeat checks.
При FAIL архив не публикуется. Неизменённые lab report и исходный tested
SHA256SUMS сохраняются отдельно, затем finalizer повторно связывает все байты.
Report для HP, NFS и физических устройств остаётся NOT TESTED.

Готовый архив содержит server+web+workers в Docker image, CI APK, unsigned IPA,
совместимый rollback image, проверяемый профиль, compatibility/runtime reports,
четыре installer/upgrader/verifier/rollback entrypoint и русские инструкции.
`SHA256SUMS` связывает каждый файл; внешний `.tar.gz.sha256` связывает весь архив.
Наличие собранного архива не заменяет физическую проверку S23/iPhone, актуальный
HP backup/restore, Synology recovery и отдельное разрешение deployment/подписи.

После успешного завершения artifact называется
`gallery-build11-distribution-<workflow run ID>`, внутри:

- `gallery-build11-5.7.3-build11.tar.gz`
- `gallery-build11-5.7.3-build11.tar.gz.sha256`

Полный commit, четыре build URL и checksum публикуются в workflow summary.
Не использовать historical defaults как Build 11 и не объявлять READY при
отсутствующем build, runtime receipt или обязательной isolated installation lab.
