# Noodle Gallery 5.7.3 (11): release candidate

Application source: `f26b46059726ca3c55c63c3ce1edde7e45d8404f`.
Release tooling имеет отдельный pinned commit; точные compiled artifacts,
контрольные суммы и CI runs включаются в package manifest после verification.

## Изменения

- Раздельные операции Gallery / Device / Everywhere в мобильном клиенте.
  Удаление на устройстве учитывает реальное подтверждение ОС и частичные отказы.
- Штатное окончательное удаление managed assets аутентифицированным владельцем.
  Для каждой external library требуется отдельное явно включённое writable mode;
  включение managed scope не разрешает удаление из внешней библиотеки.
- Сохранены ownership, shared-file references, root/mount identity, защищённый
  descriptor-relative quarantine, checksum, durable tombstones/receipts,
  revocation и повтор после прерывания. Legacy signed recovery workflow сохраняет
  проверку Ed25519, owner/scope/root и freshness; поддельные proofs не принимаются.
- Исправлен Live Photo autoplay lifecycle: initial timeline, scrolling, viewer
  return и background/resume. Ограничено количество декодеров; предусмотрены
  disposal и bounded retries. Сохранены исходные media associations.
- Подготовлены versioned checksum-verified install/upgrade/verify/rollback tools,
  private resumable signing handoff, совместимый hardened fallback и русский
  installation/user manual. API и microservices сохраняются вместе.

## Данные и upstream

Изменение схемы additive: `1794050000000-OwnerStorageDeletion`, новый
`authorizationMode`; существующие asset IDs, metadata, ownership, timestamps и
library associations сохраняются. 291 offline external index tombstone не
конвертируется в Trash и не удаляется.

Verified base: upstream `open-noodle/gallery` v5.7.1,
`da5480ae42b77db9cae729f2447ec9b3079ba4a7`. Сохранены 97 official migration files,
371 upstream API operations и все 399 исходных fork API operations структурно.
Latest v5.8.0 не включён: его обновление требует отдельной проверенной интеграции.
Полная совместимость с latest upstream не заявляется.

## Ограничения и gates

CI APK подписан disposable debug certificate: он не обновляет существующую
HP-key-signed installation. Для `Foto.apk` нужен отдельно разрешённый штатный
signing adapter с существующим ключом, без пересборки и создания нового ключа.
IPA unsigned: используется прежний SideStore, а не прямой install unsigned файла.

Production HP/NAS, физические S23/iPhone, NAS permissions, очереди и signing keys
не изменялись. Нужны свежие реальные backup/restore/NAS evidence и device acceptance.
Старые шесть FileDelete требуют проверки их фактического завершения либо отдельного
разрешения существующего scoped recovery; остальные 21 paused jobs сохраняются.
Automatic expiration использует штатную очередь: deployment не возобновляет
paused production очередь и не активирует retention автоматически.

Откат использует только упакованный migration-compatible hardened Gallery image.
Stock upstream downgrade и удаление новых tombstone/receipt tables не разрешены.
Никакие автоматически выполненные необратимые удаления этот rollback не отменяет;
восстановление originals требует проверенного backup/snapshot.

См. `BUILD11-TEST-REPORT.md`, `BUILD11-UPSTREAM-COMPATIBILITY.md`,
`BUILD11-RELEASE-RUNBOOK.md` и `BUILD11-USER-MANUAL-RU.md` в готовом пакете.
Статус установочного пакета определяется actual CI/lab reports, а не этим текстом.
