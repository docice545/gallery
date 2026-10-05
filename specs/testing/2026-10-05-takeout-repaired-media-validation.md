# Takeout albums: аудит repaired dates/EXIF и metadata-only matching

Дата: 2026-10-05. Репозиторий `docice545/gallery`, ветка `work`.
Продолжение starting HEAD `11e80b93a0ef609ad2d5b52a086033cfce31e712`.

Работа ограничена parser/matcher, synthetic tests и developer documentation.
Production, Synology originals, Gallery assets/albums/DB, external AI/auto-stack,
signing и networking не изменяются. `apply` не реализован. Оригиналы уже находятся
в Gallery/Synology; metadata-only Takeout restore сохраняет original directory
structure, все JSON filenames и album member sidecars.

Единственный реальный production owner — Anna/chudo_anna,
`bb8ccc0b-9322-40ea-9ae5-672d497b3e01`. Docice, Lenia и все остальные исключены
из реальной миграции. Generic tooling/multi-owner tests сохраняются.
Anna automatic-stack exclusion не меняется и не ограничивает album membership.
Metadata root: `/mnt/hp-data/takeout-metadata/chudo_anna`; path-map:
`/mnt/hp-data/takeout-audit/chudo_anna-path-map.json`; report:
`/mnt/hp-data/takeout-audit/chudo_anna-dry-run.json`.

## Что обнаружено в предыдущем matcher

Предыдущая policy ошибочно считала capture timestamp, сравнимый byte checksum и
file size неизменяемыми. Любое доступное несовпадение полностью отклоняло
candidate, включая совпавший путь или настоящий hash с изменённой date в Gallery.
Поэтому logical asset после date/EXIF repair мог стать `MISSING`.

Filesystem mtime уже не участвовал в matching; менять это не потребовалось.
Owner isolation, запрет filename-only matching, guard против external
`sha1-path`, streamed optional source hashing и read-only API сохранены.

Были также выявлены связанные риски: explicit path-map provenance не отделялась
от metadata staging location, а наличие любого checksum могло обойти unresolved
indexed-sidecar association даже без фактического совпадения bytes.

## Реализованная policy

Matching последовательно проверяет owner, eligibility, media type, independent
identity proof, structural compatibility и mutable metadata differences. Он не
расширяет timestamp tolerance и не использует scoring/fuzzy matching.

| Результат         | Правило                                                                                                                                                                                                                                                                                                      |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `EXACT`           | Единственный сравнимый independent content-hash match, в том числе с capture drift; либо unchanged original path + capture time/size без metadata differences                                                                                                                                                |
| `HIGH_CONFIDENCE` | Единственный operator-verified mapped path + type + совпавший Gallery `originalFileName` при metadata drift; content-hash match с inconsistent reported size; unchanged source path без второго proof; либо единственный compatible filename + capture time при отсутствии unresolved duplicates/differences |
| `AMBIGUOUS`       | Нет достаточного independent proof для существующего candidate, несколько independent proofs, unresolved duplicate/indexed association или drift не позволяет различить assets                                                                                                                               |
| `MISSING`         | Нет eligible owner-scoped candidates либо найденные candidates структурно несовместимы                                                                                                                                                                                                                       |

Capture time source — Google `photoTakenTime.timestamp`; target — текущий Gallery
`fileCreatedAt`. Capture tolerance остаётся одна секунда. `creationTime`,
`fileModifiedAt`, filesystem mtime и `updatedAt` не подменяют capture evidence.
Server не предоставляет history repair, поэтому tool не утверждает, что любое
расхождение вызвано EXIF repair.

Сравнимый content hash требует явно заданного algorithm и independent comparable
media bytes. Одинаковое значение SHA1 пути не является content proof. Different
hash algorithms не превращаются в byte mismatch. EXIF может изменить реальные
media bytes, поэтому настоящее hash mismatch записывается как difference и не
отклоняет independently proven mapped asset автоматически.

Совпавший hash сохраняет `EXACT` при capture drift. Если reported file size при
таком hash inconsistent, confidence снижается до `HIGH_CONFIDENCE` для review.
Без hash identity verified mapped path с capture/hash/size drift также даёт
`HIGH_CONFIDENCE`, а не `EXACT`.

Path proof для drift требует explicit mapping и совпавший Gallery
`originalFileName`, включая полную extension. Basename вычисленного mapped path
не заменяет original filename evidence: он повторял бы само предположение
mapping. Renamed original filename без другого proof остаётся uncertain.

Dimensions проверяются orientation-independent; video duration — точно в
milliseconds. Несовместимые dimensions или duration отклоняют candidate.
Source duration поддерживается лишь как явное `durationMilliseconds`; Gallery
DTO `duration` имеет определённые единицы milliseconds. Arbitrary numeric Google
`duration`, seconds/timecodes не угадываются. Совпавшие dimensions, duration и
size сами по себе не доказывают identity.

## Дубликаты и multiple identity proofs

Same filename или owner + filename недостаточны. Candidate с repaired timestamp
не исключается только из-за расхождения date/hash/size, чтобы другой same-name
candidate выиграл по одной совпавшей date. Без независимого различения результат
`AMBIGUOUS`.

Unique independent mapped-path/hash proof может определить asset среди weaker
filename-only candidates. Но если разные independent proofs указывают на разные
assets, например hash на один UUID, а path-map на другой, оба сохраняются в
evidence и результат остаётся `AMBIGUOUS`. Confidence labels не разрешают этот
конфликт. Byte-identical duplicates также не выбираются по list order.

Unresolved `(N)` sidecar association снимается только при реально совпавшем
comparable independent content hash. Наличие, mismatch или incomparable checksum
не позволяют угадать unindexed original. Edited/transformed item нуждается в
evidence своей версии, а не угадывается по похожему имени.

## Audit evidence и граница доверия

Mapping сохраняет `sourcePathMapping`, `sourceEvidence`, `assetEvidence`,
`identityBasis`, `metadataDifferences`, source/asset values и provenance.
Insufficient/rejected candidates также сохраняют evidence и причины.

`sourcePathMapping` — operator-verified prefix pair, а не автоматическое
доказательство происхождения NAS файла. Tool проверяет syntax, scope и equality
inventory paths; проверить historical identity обязан оператор. Неверный mapping
на другой same-name structurally compatible файл может дать `HIGH_CONFIDENCE`
с differences. Это реальный риск первого dry-run, а не подтверждённая repair.

Selected item с differences получает `requiresMetadataReview=true`; содержащий
его album — `reviewRequired=true`. Review требуется также для `EXACT` hash match
с изменённой capture date. `HIGH_CONFIDENCE` требует ручной проверки независимо
от наличия differences. Ни confidence, ни review flag не разрешают production
мутации: `apply` отсутствует.

## Обязательные regression сценарии

| Сценарий                                                  | Безопасный ожидаемый результат                               |
| --------------------------------------------------------- | ------------------------------------------------------------ |
| Unchanged original с independent proof                    | `EXACT`                                                      |
| Repaired capture timestamp, verified mapped identity      | `HIGH_CONFIDENCE` + capture difference                       |
| EXIF write изменил byte hash, verified mapped identity    | `HIGH_CONFIDENCE` + hash difference                          |
| Repaired timestamp и changed hash одновременно            | `HIGH_CONFIDENCE` при proven map; иначе `AMBIGUOUS`          |
| Изменился только filesystem mtime                         | Исходная confidence сохранена; mtime игнорируется            |
| Duplicate filename, один independent proven candidate     | Proven match; weaker candidates остаются в audit             |
| Duplicate filename и repaired date не позволяет различить | `AMBIGUOUS`, без timestamp-only winner                       |
| Same filename другого owner                               | Никогда cross-owner match                                    |
| Video repaired date, stable mapped identity               | `HIGH_CONFIDENCE`; доступные dimensions/duration проверяются |
| Edited/transformed Google item без proof своей версии     | `AMBIGUOUS` или `MISSING`, без guessed match                 |
| Proven asset в нескольких album directories               | Один Gallery UUID в нескольких native membership proposals   |
| JSON-only tree без adjacent media                         | Поддерживается; нет выдуманного content hash или import      |

Все перечисленные сценарии покрыты regression tests. Различия не превращают
inadequate evidence в confidence.

## Достаточность metadata-only Takeout

**Копировать/импортировать примерно 200 GB originals не нужно.** Existing
Gallery inventory, verified paths и настоящая JSON metadata позволяют делать
owner-scoped dry-run без media beside JSON и без записи в Synology.

Но JSON-only restore не даёт всех optional evidence paths:

- `--hash-media` не получает independent SHA1/size из absent original Takeout
  media. Repaired Synology target нельзя хешировать для самоподтверждения mapping.
- Presence соседнего original не помогает resolve sidecar-named `(N)` association;
  unresolved records остаются ambiguous без настоящего independent hash proof.
- Common sidecars часто не содержат size/dimensions/duration/checksum. Missing
  fields допустимы, но не заполняются предположениями.

Если NAS layout не соответствует Takeout, dates repaired и sidecars не дают
другого proof, конкретный item остаётся `AMBIGUOUS`/`MISSING`. Возможен отдельный
ограниченный read-only audit архивных original bytes/verified manifest для таких
items; это не обязательный перенос всей библиотеки и не implemented apply.

Year-directory sidecars не доказывают album membership. Restore должен сохранить
album metadata и member sidecars внутри каждой album directory, полный Photos
tree и original `.json`/`.supplemental-metadata.json`/truncated/`(N)` filenames.
Один уже существующий Gallery asset законно входит в несколько albums.

## Проверки

| Проверка                         | Результат                                                   |
| -------------------------------- | ----------------------------------------------------------- |
| Baseline до изменений            | 94 passed: 79 parser/matcher/CLI + 15 read-only API adapter |
| Новые repaired-media regressions | 36 passed; fixtures синтетические, включая Anna owner scope |
| Полный финальный Python suite    | 130 passed: 79 existing + 15 API + 36 new                   |
| Ruff format/check                | Все пять Python файлов чистые                               |
| Python compile                   | Passed                                                      |
| `git diff --check`               | Passed                                                      |

Применение новых policy tests к исходному matcher подтвердило недостатки baseline:
22 из первых 32 новых tests не прошли. Это число test failures, а не утверждение
о 22 отдельных production bugs. После исправлений все 36 новых tests прошли.

Первый regression run старых 94 tests после изменения policy выявил два прежних
expectations: unmatched repaired date раньше считалась `MISSING`, теперь safe
`AMBIGUOUS`; comparable original-byte hash mismatch при verified mapped identity
раньше полностью отклонял asset, теперь остаётся `HIGH_CONFIDENCE` с независимой
source evidence. Эти assertions обновлены под новое безопасное поведение с
проверкой reasons/differences; финальный полный run чистый.

Regression suite проверяет deterministic reports, source immutability,
metadata-only media-read guard, owner isolation, structural mismatches, competing
proofs, indexed associations и item/album review flags. Production dry-run и
physical Synology validation не выполнялись: реальные restored JSON ещё нужны.
Flutter/server/native код не менялся, поэтому unrelated suites не запускались.

Standalone offline CLI smoke для JSON-only repaired-date photo: HIGH_CONFIDENCE,
item/album review=true, два byte-identical reports, permissions 0600, source files
неизменны; adjacent media, network и apply не использовались. Лог полного suite:
`/workspace/gallery-validation/takeout-repair-final.log` (Cloud, не production).

## Первый реальный Anna/chudo_anna dry-run: пока не запускался

Из этой Cloud-среды не подтверждены Anna restored JSON и исходное tree,
actual production paths, verified Anna path-map, Anna read-only credentials и
private audit directory. Поэтому real-data dry-run остановлен на подготовке;
для docice/Lenia реальных данных не готовили и команд не выполняли.

До запуска проверить owner export, настоящие server container `originalPath`,
каждый prefix mapping и basename/originalFileName evidence. Особое внимание:
same-name duplicates, repaired items, edited/indexed sidecars, hash comparability,
missing structural metadata и поля `requiresMetadataReview`/`reviewRequired`.

Report сохраняется вне source/media roots. Сначала разобрать `AMBIGUOUS`,
`MISSING`, metadata differences и competing proofs; количество matches не является
доказательством безопасности. Никакой album creation, asset update, metadata
rewrite или media upload на этом этапе нет.

## Git

Starting SHA указан выше. Новые commit SHA, final HEAD, `origin/work` и status
основная сессия укажет в финальном ответе после обычного push. Hash этого самого
отчёта/коммита нельзя заранее встроить в committed file без self-reference.
История не переписывается, production deployment не выполняется.
