# Испытания foto-build17-release

Дата: 22.10.2026. Код: `58cf4dbd8e04fc46d79e34761e4ec16214c91540`.
Cloud, **не HP**. Production/NAS/реальные медиа не использованы.

```bash
python3 -m unittest discover -s tools/foto-automation/tests -p test_build17_release.py -v
python3 -m py_compile tools/foto-automation/foto-build17-release tools/foto-automation/tests/test_build17_release.py
```

Итог: **44/44 PASS**, 7.692 s. Python syntax и git diff check: PASS.
Лог запуска: `/tmp/foto-build17-release-tests-final-44.log` в Cloud. Число относится
только к orchestration tests, не к backend/mobile тестам внутри будущего конвейера.
Новый workflow `.github/workflows/foto-build17-release.yml` повторяет этот
изолированный suite без Docker, Android SDK, моделей или HP.

| Проверка                                                    | Реальное подтверждение                                                      | Результат                    |
| ----------------------------------------------------------- | --------------------------------------------------------------------------- | ---------------------------- |
| Чистый Git, интеграция двух веток, исходная ветка сохранена | Настоящие временные git repos/commits/worktree/merge                        | PASS                         |
| Dirty и untracked файлы                                     | Реальные файлы остаются неизменны; fetch не выполняется                     | PASS                         |
| Повтор prepare                                              | Не создаёт второй merge, HEAD неизменен                                     | PASS                         |
| PR уже cherry-picked / merged                               | Реальные patch-id / ancestry, merge пропущен                                | PASS                         |
| Конфликт                                                    | Реальный Git conflict сохранён, base не меняется, повтор закрыт             | PASS                         |
| Отсутствующий/draft/closed/unapproved PR                    | Mock GitHub; не принимается                                                 | PASS (mock)                  |
| Другой owner repo/base/head / fetched SHA                   | Mock GitHub/fetch boundary + настоящие local refs                           | PASS                         |
| Красный/пустой/pending/cancelled CI                         | Mock GitHub gates; required checks не допускают skip                        | PASS (mock)                  |
| Параллельный release и FOTO stage                           | Настоящий flock на temporary files                                          | PASS                         |
| Активный Codex                                              | Mock process inventory, запуск блокируется                                  | PASS (mock)                  |
| Повреждённый checkpoint / изменённый config                 | Реальные private JSON и immutable snapshots                                 | PASS                         |
| False PASS, изменённый log/output/request SHA               | Реальные hashes/файлы, fake child command                                   | PASS                         |
| Exit 137 и interrupted/RUNNING                              | Mock child failure, без auto retry, требуется diagnosis                     | PASS (mock, не реальный OOM) |
| Остановка сигналом                                          | Настоящий Linux child посылает TERM supervisor, exit 143, FAIL              | PASS                         |
| Недостаточно памяти                                         | Mock resource snapshot; child не запущен                                    | PASS (mock)                  |
| Resume только последнего режима                             | Mock dispatcher: build не запускает prepare/test/verify                     | PASS (mock)                  |
| Check не пишет state                                        | Настоящий temp Git/files + mocked remote/Docker; state/source без изменений | PASS                         |
| Отсутствующий signing key                                   | Файл не создаётся и не заменяется                                           | PASS                         |
| Неверная/debug подпись, package/version                     | Synthetic zip, mock apksigner/aapt output; отказ                            | PASS (mock)                  |
| Несоответствие image source                                 | Mock Docker image metadata; отказ                                           | PASS (mock)                  |
| Чужой Docker endpoint                                       | Mock context; запрос к daemon не отправляется                               | PASS (mock)                  |
| Память/parallelism/активная история builder                 | Mock Docker/tar config/history; отказ, без изменения builder                | PASS (mock)                  |
| Versioned copy, повтор, подмена                             | Настоящее копирование synthetic bytes, atomic publish, 0644                 | PASS                         |
| Неверный delivery user                                      | Отказ без sudo/escalation                                                   | PASS                         |
| Обязательный режим/help                                     | Настоящий CLI, отсутствующий/двойной mode → exit 2                          | PASS                         |
| Пути 34 выбранных backend/mobile тестов                     | Сверены с pinned Git trees базы и PR #6/#7; не выполнялись                  | MATCH (static source)        |
| HP rootless builder, BuildKit JSON и реальные limits        | HP недоступен, контейнеры/сборки не запускались                             | NOT VERIFIED                 |
| Реальный backend image и runtime health                     | В этом задании не собирались/не запускались                                 | NOT VERIFIED                 |
| Реальный подписанный APK/сертификат/устройство              | В этом задании не собирался, ключ не получался                              | NOT VERIFIED                 |
| Android/iOS/Web приложения, Synology, AI                    | Не исполнялись                                                              | NOT VERIFIED                 |

Сохранённые development runs: первые 33 проверки прошли; при добавлении новых
кейсов был один дефект размещения кода в самом тесте (38-case run: 1 error), он
исправлен восстановлением assertions, затем 38/40/41/42-case runs PASS; новый recipe assertion в 43/44-case run ошибочно считал single-package `pnpm run build` параллельным. Исправлена область assertion, итоговый 44-case run PASS. Эти counts
не складываются. Обработка OOM 137 — fault injection, не доказательство реального
устранения OOM на HP. Локальные Git-тесты не выданы за GitHub или Android E2E.

## Текущие ограничения приёмки

- Пример config блокирует prepare до ручной приёмки точных SHA. PR #6 и #7 на
  момент проверки имеют незелёный CI; финальная интеграция/сборка поэтому **BLOCKED**.
- Неизвестны фактические HP tool PATH, signing paths/public certificate pin,
  поддерживаемый buildx JSON/history и свободные ресурсы. Их проверяет check и
  последующие preflight. Ничего не заменяется предположениями из Cloud.
- Native iOS/Android E2E и NAS нельзя сертифицировать backend contract-тестами.
- Успешный Docker build доказывает получение image, не его работоспособность.
- Новые release tools не исправляют посторонние CI/редактор/backend дефекты.

Инструкция: [FOTO_BUILD17_RELEASE.md](FOTO_BUILD17_RELEASE.md).
