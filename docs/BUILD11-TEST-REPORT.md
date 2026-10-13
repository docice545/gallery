# Gallery Build 11: подтверждённые результаты проверок

Application source: `f26b46059726ca3c55c63c3ce1edde7e45d8404f`.
Версия: `5.7.3 (11)`. Production не участвовал в проверках.

## Завершённые application gates

| Проверка                                        |  PASS | Ожидаемые / пропущенные        |         FAIL |
| ----------------------------------------------- | ----: | ------------------------------ | -----------: |
| Финальный полный backend unit suite             | 6 858 | 1 expected failure, 12 skipped | 0 unexpected |
| Финальный полный PostgreSQL 14 medium suite     | 3 370 | 12 skipped                     |            0 |
| Полный Flutter suite, сохранённый результат     | 4 697 | 1 skipped                      |            0 |
| Полный web suite, сохранённый результат         | 6 458 | 2 skipped, 4 TODO              |            0 |
| Chromium Live Photo lifecycle                   |     8 | synthetic MP4 и mocked API     |            0 |
| Filesystem, signed recovery и guard regressions |   205 | входит в backend gates         |            0 |

Backend unit: 212 файлов passed, 1 skipped; duration 238.05 s.
PostgreSQL: все 189 файлов passed; duration 443.44 s.
Ожидаемая baseline ошибка: `timeline.controller.spec.ts` →
`should fail if time bucket is invalid` (`it.fails`). Она не скрывается и не
считается подтверждением корректного отклонения invalid time bucket.

Полные final backend/PG suites заменяют незавершённые post-fix gates из старого
handoff. Flutter/web/browser не запускались повторно: application source не менялся.
Backend TypeScript, Flutter analyze, web TypeScript/Svelte, scoped ESLint и
форматирование прошли в предыдущей сессии на тех же application inputs.

Команды из корня repository, после активации pinned toolchain:

```bash
pnpm --config.verify-deps-before-run=false --dir server exec vitest --config test/vitest.config.mjs --run
pnpm --config.verify-deps-before-run=false --dir server exec vitest --config test/vitest.config.medium.mjs --run --maxWorkers=2 --testTimeout=30000 --hookTimeout=30000
```

PostgreSQL работал исключительно в disposable testcontainers на проверенном
облачном Docker socket. Применена additive migration
`1794050000000-OwnerStorageDeletion`; использованы настоящие pinned public
test-assets и штатно собранный core plugin WASM. Production DB и NAS не подключались.

SHA-256 финальных локальных логов:

- Backend unit: `35cb2b0816979fa89a1e7c8aa52ce1a09793475d7c3f4bde680139f2a69344b4`.
- PostgreSQL 14: `c2f89658dc2e389950b1c2c4193476eaa59f2e656c0f789371887b15ca840b5e`.

## Границы доказательств

Автоматические проверки используют disposable DB, файлы и пользователей.
Это доказательство application behavior в изолированной среде, а не успешного
удаления с production Synology или на Samsung/iPhone.

Следующие проверки остаются отдельными operator/device gates:

1. Свежий backup реальной HP DB и успешное восстановление именно этих байтов.
2. Реальные NAS recovery evidence, NFS root identities и разрешения конкретных
   библиотек; никаких искусственно обновлённых timestamps или fabricated proofs.
3. Состояние шести legacy FileDelete и неизменность остальных 21 paused jobs.
   Нельзя считать старый журнал подтверждением ещё не проверенного выполнения.
4. Обновление S23 существующим HP-key-signed APK без uninstall и утраты данных.
   CI debug signature не является подписью HP. Private key в CI не используется.
5. Подпись unsigned IPA через существующий SideStore и проверка расширений.
6. OS-confirmed local deletion, denial/partial failures, фон/перезапуск и Live
   Photo playback на физических Android/iOS.
7. Thumbnail/preview, upload/sync, albums/search/face recognition и rollback
   acceptance на HP после отдельно разрешённого deployment.

Настоящие CI run IDs, artifact identities, package SHA-256 и installation lab
report публикуются отдельно после завершения соответствующих операций. Наличие
этого документа не создаёт CI PASS и не разрешает production deployment.
