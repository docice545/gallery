# Build 10: отдельный hardened rollback source

Целевой application source и уже готовый образ остаются
`ea51a8acdc6f18ab5917c19b6f3833d740b4e9ba` и
`sha256:4d4f9d581a654713b6d305f9aa1341b302fd36fc4ef7fca832dcb94de4004e75`.
Этот source предназначен только для отдельного fallback-образа. Он не является
доказательством происхождения старого HP image `828523317…` и не применяется
вместо целевой сборки автоматически.

## Что откатывается

HTTP API подготовки политики возвращён к проверенному состоянию непосредственно
перед ea51, `95ee6906cb360279de9e56428b90ff529d39ea2c`: отсутствуют два новых
`assets/admin/*-deletion-preparation` endpoint для подготовки за другого owner.
Administrator preparation собственных roots, индивидуальные owner consent/revoke,
Trash, Restore, permanent-deletion preflight и все обычные API остаются.
SDK/OpenAPI соответствуют этому API. На fallback подготовка за других владельцев
временно недоступна; после устранения причины rollback вернуться на целевой образ.

Это ограниченный функциональный rollback нового administrator API, а не retag,
подстановка SHA в старый образ или обещание восстановить неизвестный старый source.
Все остальные runtime/build inputs сохранены из ea51, включая новые recovery,
NFS/root-squash, quarantine и filesystem-security исправления.

## Что никогда не откатывается

Следующие шесть security modules и оба migration directories не изменяются:

- `utils/authorized-deletion`
- `utils/deletion-recovery`
- `repositories/asset.repository`
- `repositories/storage.repository`
- `services/asset.service`
- `services/library.service`

В cloud compilation сравнение всех шести скомпилированных JS modules и всех
170 скомпилированных migrations с ea51 прошло побайтово. 465 relevant backend
tests прошли, включая signed recovery, filesystem security, shared originals,
managed/external scope isolation, interrupted deletion и новый rollback API boundary.
Это не заменяет проверку конкретных Docker images: HP preflight обязан сравнить
реально упакованные modules/migrations целевого и fallback images, source,
platform, version, worker configuration и live database inventory.

## Сборка и применение

Собирается только этот fallback source стандартным `server_build.sh` из чистого
checkout. Он получает собственный реальный Git SHA через `BUILD_SOURCE_COMMIT`;
не перезаписывать metadata старого image и не присваивать ему SHA ea51.
Version остаётся 5.7.3, mobile build 10; APK/IPA не пересобираются.
Точный immutable source/manifest/image ID передаёт отдельный release tooling.

Build не запускает workers, не использует production Compose/volumes, не меняет
production containers, queues, policy consent или retention. CI smoke использует
только isolated PostgreSQL/Redis и disposable fixtures. Не запускать этот smoke
на HP с production URL или volumes.

Перед deployment должен успешно пройти полный `image_release.py plan` с явными
`--rollback-image`, `--rollback-source-commit`, `--rollback-server-version`.
Не ослаблять matching migrations/guards, image-only configuration, recovery,
scope/owner isolation или worker requirements. API и microservices остаются
вместе; inpainting/ML/Memories и остальные сервисы не пересоздаются.

Rollback требует отдельного подтверждения. Он не возвращает удалённые originals
и не откатывает database receipts/tombstones/consent. После любого recreation
старые root/mount-namespace proofs могут быть недействительны: новый proof
выпускается только после реальных актуальных recovery checks и индивидуального
согласия владельца. 291 offline index tombstones не мигрируются и не удаляются.
