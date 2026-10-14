# Gallery 5.7.3 (11): финальная Cloud-передача

**Compiled distribution: BUILT / VERIFIED IN ISOLATED CI / PUBLISHED.**
**Production verdict: BLOCKED_OPERATOR_ACCEPTANCE.** HP deployment, production
signing, реальные NFS-операции и physical-device acceptance не выполнялись.

## Точная версия и происхождение

- Ветка: `candidate/gallery-5.7.3-build11-upstream`; main/work не изменены.
- Application source всех трёх компонентов:
  `89447178806ccc509ff0b52358b7491842041047`, **5.7.3 (11)**.
- Проверенный release tooling: `ec9a67ab8df18d0509bd61e4642efd69d6b48c86`.
- [Final CI38553886139 — SUCCESS](https://github.com/docice545/gallery/actions/runs/38553886139).
- Upstream: [open-noodle/gallery](https://github.com/open-noodle/gallery),
  v5.7.1 `da5480ae42b77db9cae729f2447ec9b3079ba4a7`.
  Все97 upstream migration entries сохранены;371 API operations структурно
  сохранены. v5.8.0 не интегрирован. Это не доказательство всех production workflows.
- Неопубликованные изменения HP неизвестны и не считаются интегрированными.

## Downloadable artifacts

| Компонент           | GitHub Actions artifact                                                                                                                | Статус                                                                          |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Полный пакет        | [gallery-build11-distribution-38553886139](https://github.com/docice545/gallery/actions/runs/38553886139/artifacts/11889198511)        | SUCCESS; backend/web/workers, APK/IPA, installer/upgrade/verify/rollback и docs |
| Backend/web/workers | [gallery-trash-server-linux-amd64](https://github.com/docice545/gallery/actions/runs/38484089051/artifacts/11858938573)                | SUCCESS                                                                         |
| Android             | [android-media-pilot-validation-apk](https://github.com/docice545/gallery/actions/runs/38486187028/artifacts/11861136880)              | SUCCESS; CI debug signature, не HP update                                       |
| iOS                 | [ios-unsigned-ipa](https://github.com/docice545/gallery/actions/runs/38484090958/artifacts/11860071853)                                | SUCCESS; unsigned, требуется существующий SideStore                             |
| iOS archive         | [ios-unsigned-archive](https://github.com/docice545/gallery/actions/runs/38484090958/artifacts/11859008510)                            | SUCCESS                                                                         |
| Final proof reports | [gallery-build11-verification-report-38553886139](https://github.com/docice545/gallery/actions/runs/38553886139/artifacts/11889158469) | Published; actual isolated reports                                              |

Actions retention пакета —14 дней. Сохраните проверенный package для последующей
установки и rollback. GitHub может требовать авторизованный доступ к artifacts.

Публичные **inner-file** SHA-256 из actual CI receipt:

| Файл                                   | SHA-256                                                            |
| -------------------------------------- | ------------------------------------------------------------------ |
| `gallery-build11-5.7.3-build11.tar.gz` | `c222d155d68ec84abd8e62337e00b666032f162ac07989b1e3e9ab32af6bfa81` |
| Пакетный `SHA256SUMS`                  | `5b7a580b4174e47be059abec24a6a20640adf9ca9b1a98c3b308621687429c83` |
| Backend archive                        | `4a764b110ba0ffc2603b0219234811c1873c55b981cc59eed1cca30cc0e28d8d` |
| `app-release.apk`                      | `5453796e99c11d8bd2110f7b60726f02c8d2c9dac0ffbbbcfdb4b5a136200934` |
| `Photos-unsigned.ipa`                  | `69882d5de38ec46e11217a350bb49af5adcfb67aeaead20220c637e60e678652` |

Backend config image ID:
`sha256:bd078fdd96f29950d77ee28977e4cd9592d5cd8f5a2ee5afd07fa0c4e5a45044`.
Docker containerd aliases принимаются только по проверенному archive descriptor graph.
Artifact ZIP digest `3e4270aa7c2255d9a066979fce618ff672090158e50e3ca65dc799b2a70952d3`
относится к GitHub ZIP, а не к внутреннему tar.gz.

## Одна команда получения и проверки, без deployment

На HP выполнять как `doctoriceadm` с существующим доступом `gh` к GitHub.
Блок пишет только в новую private staging-directory. Не использует sudo,
Docker, production checkout, ключи подписи или исходные media.

```bash
set -euo pipefail
umask 077
DOWNLOAD=$(mktemp -d "$HOME/gallery-build11-package-XXXXXXXX")
gh run download 38553886139 --repo docice545/gallery \
  --name gallery-build11-distribution-38553886139 --dir "$DOWNLOAD"
printf '%s  %s\n' \
  c222d155d68ec84abd8e62337e00b666032f162ac07989b1e3e9ab32af6bfa81 \
  "$DOWNLOAD/gallery-build11-5.7.3-build11.tar.gz" | sha256sum -c --strict -
PACKAGE="$DOWNLOAD/package"
mkdir -m 0700 "$PACKAGE"
tar --extract --gzip --file "$DOWNLOAD/gallery-build11-5.7.3-build11.tar.gz" \
  --directory "$PACKAGE" --no-same-owner --no-same-permissions --keep-old-files
printf '%s  %s\n' \
  5b7a580b4174e47be059abec24a6a20640adf9ca9b1a98c3b308621687429c83 \
  "$PACKAGE/SHA256SUMS" | sha256sum -c --strict -
(cd "$PACKAGE" && sha256sum -c --strict SHA256SUMS)
python3 -B - "$PACKAGE" <<'CHECK'
import sys
from pathlib import Path
package = Path(sys.argv[1])
sys.path.insert(0, str(package / 'tools'))
from gallery_entry import verify_package
config = verify_package(package)
if (config['sourceCommit'] != '89447178806ccc509ff0b52358b7491842041047' or
        config['version'] != '5.7.3' or config['build'] != 11 or
        config['installationValidation']['status'] != 'ACTUAL_ISOLATED_PASS_HP_AND_DEVICES_NOT_TESTED'):
    raise SystemExit('STOP EXACT_VERIFIED_BUILD11_PACKAGE_REQUIRED')
print('PASS exact compiled release package; deployment/signing not executed')
CHECK
printf 'PACKAGE=%s\n' "$PACKAGE"
```

После этого используйте [полный русский runbook](BUILD11-RELEASE-RUNBOOK.md):
он содержит отдельные команды prepare/check, tmux upgrade, clean install,
rollback, HP signing и SideStore. Не выполняйте `upgrade/apply` без отдельного
разрешения. Не обновляйте timestamp старого recovery evidence; refresh создаёт
новый backup и проверяет его isolated restore.

## Доказательства тестирования

- Final CI: **31 required actual isolated checks PASS**, successful cleanup и
  строгий checksum sealing. Предыдущий385515 lab также PASS (32true:31required
  +fixture), но его sealing-отказ устранён текущим tooling.
- Actual clean install/resume/repeat, Build10 upgrade/additive migration,
  asset/user/album/sharing preservation,27 paused jobs bytes/order preservation,
  managed/external physical deletion synthetic originals, mixed-scope safety,
  rescan tombstones, thumbnail/preview files+HTTP, fresh upgraded backup isolated
  restore и hardened rollback после injected failure — **PASS в CI**.
- Новые snapshot regressions: **4 actual PostgreSQL14 PASS**.
- Read-only imports/finalizer: **48+16 tests PASS**, включая воспроизведение
  исходного unsealed bytecode и отказ на постороннем файле. Docker21 и прочие
  ранее пройденные suites не повторялись без изменения inputs.
- Сохранённые application suites: backend6858PASS/1expected/12SKIP;
  PostgreSQL3370PASS/12SKIP; Flutter4786PASS/1SKIP; analyze No issues;
  web6458PASS/2SKIP/4TODO; Chromium Live Photo8PASS. Scoped tests входят
  в полные suites и не прибавляются к общему числу повторно.

Final CI log подтверждает genuine lab/upstream reports sealed и сохраняет
явные operator gates. Последний small report download в Cloud был network-denied;
использован успешный CI log/strict finalizer, а не повторное скачивание1.3GB.
Полный [test report](BUILD11-TEST-REPORT.md) хранит точные ограничения.

## Оставшиеся operator gates

| Проверка                                                      | Статус / следующий шаг                                                                                 |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Текущая HP database, recovery, реальный upgrade и rollback    | NOT TESTED; fresh backup+isolated restore, live preflight, отдельное разрешение deployment             |
| Synology NFS/root squash, per-library writable mode, recovery | NOT TESTED для candidate; актуальное recovery evidence и проверенные roots, отдельное owner opt-in     |
| Реальные6 legacy jobs и21 paused jobs                         | NOT TESTED; scoped подтверждение фактического состояния, no replay/clear, остальные jobs сохраняются   |
| Production Android update                                     | BLOCKED до HP подписи существующим ключом; CI APK нельзя ставить поверх HP-signed app                  |
| SideStore iPhone update/extensions                            | NOT TESTED; unsigned IPA подписывается существующим SideStore/Personal Team, сохранить extension route |
| S23/iPhone offline/background/OS denial/retry/Live Photos     | NOT TESTED; disposable acceptance по runbook/user manual                                               |
| Automatic retention / real media destructive tests            | НЕ АКТИВИРОВАНО; требуется отдельное явное разрешение                                                  |

CI APK certificate:
`f02566bc4479f9a4668baf829fe909ca06acaa44d723f1360b0e5db7d311e0f3`.
Ожидаемый HP certificate:
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
Не удалять установленное приложение, не очищать данные и не генерировать новый ключ.

[Русский user manual](BUILD11-USER-MANUAL-RU.md) описывает Gallery/Device/Everywhere,
Trash/Restore, NAS writable opt-in и Live Photos. [Acceptance](BUILD11-ACCEPTANCE.md)
задаёт disposable проверки и критерии остановки. API и microservices должны
работать; image-only deployment/rollback сохраняют остальные контейнеры, mounts,
volumes, networks и не используют `down -v` или `--remove-orphans`.

Image-only transition принимает только проверенный compatibility receipt для
`1794050000000-OwnerStorageDeletion` и actual hardened rollback. Global
`backgroundTask` не активировать автоматически: текущую HP pause и остальные
21 jobs необходимо сохранить и повторно проверить.
