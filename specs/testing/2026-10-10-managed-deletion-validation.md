# Managed deletion consent validation

Application baseline: `e6ab95e695f085c3016072ebff44d4ba02695cb5`.
Backend/API commit: `a895fd79fd74c8714213939434b1e8f7b157ffa5`.
Client commit: `77404b9e9bcbeda9f4e9627981437c03a892f920`.
No production access, NAS writes, signing, release images/APKs or CI release
workflows were used. PostgreSQL fixtures and originals are disposable and isolated.

## Automated results

| Check | Result |
| --- | --- |
| Existing asset/trash/library/storage unit checks | PASS, 323 tests / 4 files |
| Managed-consent service/DTO tests | PASS, 13 tests / 1 file |
| PostgreSQL authorized deletion + retention lifecycle + timeline | PASS, 50 tests / 3 files |
| Flutter selected Trash/Restore/sync/cleanup/API/widget checks | PASS, 308 tests / 12 files |
| Web settings + selective/Empty Trash | PASS, 17 tests / 3 files |
| Server build, migration synchronization, TypeScript | PASS; no new migration |
| Server ESLint on changed source/tests | PASS |
| Web TypeScript and Svelte | PASS; zero Svelte errors/warnings |
| Web ESLint on all changed source/tests | PASS with pinned JS TypeScript 6.0.2 (see environment note) |
| Flutter scoped analyze --fatal-infos | PASS; no issues |
| Dart, Prettier, git diff whitespace | PASS |
| OpenAPI JSON + TypeScript/Dart SDK + translation generation | PASS, established generators |
| Operator template | Bash/Python syntax PASS; HP execution NOT TESTED |

Counts above refer to distinct checks, not repeated runs. Full Flutter/backend
suites and native Android/Xcode release builds were not repeated for this patch.
Flutter 3.47.2 / Dart 3.13.2; Node 24.21.0; Vitest 4.1.11; OpenAPI Generator 7.25.0.

The shared cloud node_modules cache resolved `typescript` in `tscompat` to the
SDK's native TypeScript 7 version shim (no SymbolFlags), rather than the web's
locked JavaScript TypeScript 6.0.2. Ordinary ESLint crashed on an unchanged
baseline test too. A temporary environment-only Node resolution adapter selected
the already installed **locked 6.0.2** compiler for the ESLint run. Every rule
remained enabled; no package, lockfile or lint configuration was changed. It then
identified/fixed the new lint errors and completed with exit 0. Clean validation
must install/resolve the declared web compiler correctly; an unqualified run with
the broken shared cache is not a successful lint check.

## Safety and acceptance matrix

| Requirement | Automated status and evidence | Remaining operator/device gate |
| --- | --- | --- |
| A: confirmed offline external Active + deletedAt | PASS: unchanged, excluded from Trash; original retained | Production aggregate is owner-provided; no conversion authorized |
| B: managed Active + deletedAt of unknown intent | PASS: no invented Trash/migration | Investigate separately if such records are ever found |
| C/D: Active without date; existing Trashed | PASS: query/Timeline fixtures retain distinction | Check actual UI counts after update |
| E: idempotence | PASS: read-only queries; repeated consent/Empty Trash tests | No migration to run |
| F/G: managed blocked/explicitly allowed | PASS: no policy preserves file; prepared consent guarded unlink succeeds | Real recovery attestation and explicit owner grant; disposable device test |
| H/I: external defaults/scope isolation | PASS: managed permission never grants external deletion; original retained | No automatic or production external opt-in |
| J/K: mixed scopes/selective/Empty | PASS: full preflight, including >200 items; zero new unlink on missing scope | A concurrent revocation or unlink failure cannot undo earlier completed actions; inspect receipts |
| L: interrupted deletion | PASS: existing fail/retry/pair receipt fixtures retained | Physical network loss and device restart |
| M: shared original, path/inode/hash protection | PASS: original guard fixtures; no safeguard removed | Verify actual managed roots/exclusive namespace before grant |
| N: Android/shared Flutter and web UI | PASS: Russian narrow high-DPI widget, consent confirmation, blocked/prepared states, web interactions | Physical S23 and iPhone NOT TESTED |
| Background thumbnail/preview processing | Configuration template rejects API-only/excluded microservices | Production upload, both image APIs, job completion and viewing NOT TESTED |

The 291 production offline rows are **not** missing user Trash. The 12 genuine
managed Trash rows still require preparation + explicit consent. Existing build 9
artifacts do not implement this patch. Code is ready for review; production release
requires review, a coherent new artifact build, signing/device acceptance and
separate deployment approval. External-library physical deletion stays disabled
unless individually authorized; managed originals on NAS are covered only by an
explicit managed grant with their actual roots/recovery evidence verified.

Deployment/rollback: [operator instructions](../../docs/MANAGED-DELETION-AUTHORIZATION.md).

## Modified files

- `docs/MANAGED-DELETION-AUTHORIZATION.md`
- `i18n/de.json`
- `i18n/en.json`
- `i18n/es.json`
- `i18n/fr.json`
- `i18n/it.json`
- `i18n/nl.json`
- `i18n/pl.json`
- `i18n/ru.json`
- `i18n/zh_Hans.json`
- `i18n/zh_Hant.json`
- `mobile/lib/domain/models/deletion_result.model.dart`
- `mobile/lib/presentation/actions/delete.action.dart`
- `mobile/lib/presentation/pages/trash.page.dart`
- `mobile/lib/presentation/widgets/managed_deletion_dialog.dart`
- `mobile/lib/repositories/asset_api.repository.dart`
- `mobile/lib/utils/deletion_message.dart`
- `mobile/test/presentation/widgets/managed_deletion_dialog_test.dart`
- `mobile/test/repositories/permanent_deletion_api_repository_test.dart`
- `open-api/immich-openapi-specs.json`
- `packages/sdk/src/fetch-client.ts`
- `server/src/controllers/asset.controller.ts`
- `server/src/controllers/trash.controller.ts`
- `server/src/dtos/asset-deletion.dto.ts`
- `server/src/repositories/asset.repository.ts`
- `server/src/services/asset.service.ts`
- `server/src/services/managed-deletion.service.spec.ts`
- `server/test/medium/specs/services/authorized-deletion.spec.ts`
- `server/test/medium/specs/services/trash-retention-lifecycle.spec.ts`
- `server/test/repositories/asset.repository.mock.ts`
- `specs/2026-10-10-managed-deletion-consent-design.md`
- `specs/testing/2026-10-10-managed-deletion-validation.md`
- `web/src/lib/components/shared-components/ManagedDeletionSettings.spec.ts`
- `web/src/lib/components/shared-components/ManagedDeletionSettings.svelte`
- `web/src/lib/services/trash-authorization.spec.ts`
- `web/src/lib/services/trash.service.ts`
- `web/src/lib/utils/actions-deletion.spec.ts`
- `web/src/lib/utils/actions.ts`
- `web/src/lib/utils/deletion-message.ts`
- `web/src/routes/(user)/trash/[[photos=photos]]/[[assetId=id]]/+page.svelte`
