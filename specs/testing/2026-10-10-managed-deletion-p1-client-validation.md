# Managed deletion security client validation

Source baseline: `dcc78926fbd89ffcf1a8f8ccc4702859a135166b`.
Mobile candidate version: `5.7.3+10` (previously `5.7.2+9`). Package identity and
signing configuration are unchanged. This is a source version change; no release
APK, AAB, IPA or container image was built or published.

This record updates the client validation in
[the original managed-deletion validation](2026-10-10-managed-deletion-validation.md)
for the signed recovery-evidence contract. Administrator preparation uses the
digest of trusted, locally installed Ed25519-signed evidence. It remains separate from
the owner's explicit managed-storage consent and does not authorize external
libraries.

## Automated client results

| Check                                                            | Result                                              |
| ---------------------------------------------------------------- | --------------------------------------------------- |
| Flutter selected Trash/Restore/sync/cleanup/API/widget checks    | PASS, 317 tests / 12 files                          |
| Full Flutter suite on final stable source                        | PASS, 4,651 tests; zero failures; one skipped suite |
| Web settings + selective/Empty Trash                             | PASS, 24 tests / 3 files                            |
| Flutter scoped analyze `--fatal-infos`                           | PASS, no issues                                     |
| Web Svelte check                                                 | PASS, zero errors and warnings                      |
| Web TypeScript `--noEmit`                                        | PASS                                                |
| Web ESLint on changed source/tests                               | PASS, zero errors and warnings                      |
| Shared translations in ten locales, Prettier and Dart formatting | PASS                                                |

Flutter 3.47.2 / Dart 3.13.2, Node 24.21.0 and Vitest 4.1.11 were used. Translation
keys and the loader were regenerated with the existing repository generators.
The web lint run used the existing environment-only adapter for the locked
JavaScript TypeScript 6.0.2 compiler because the shared node_modules cache
otherwise resolves the SDK's native TypeScript shim. No dependency, lockfile,
lint configuration or rule was changed.

All 2,829 fingerprinted mobile source, test, generated/OpenAPI and locale inputs
remained unchanged throughout the final full run. The 317 focused Flutter tests
are included in the full-suite count. The existing
`test/modules/map/map_theme_override_test.dart` suite retains its
`@Skip('Flaky test, needs investigation')` annotation; its six declared widget
cases did not execute. No skip was added for this patch.

An unchanged album-thumbnail widget test timed out during an earlier run. Its
seven-test file passed in isolation, and the final full suite passed that test
and every other executed test. No failing baseline check remains from these
client validations.

## Backend baseline control

The two failing backend guards were repeated separately, using the same Node
24.21.0, Vitest 4.1.11, dependencies and test configuration. This was a focused
baseline comparison, not a repeat of the full backend suite.

| Source                                                        | Selected guard result                                          |
| ------------------------------------------------------------- | -------------------------------------------------------------- |
| Immutable baseline `e6ab95e695f085c3016072ebff44d4ba02695cb5` | 33 passed, 2 failed, zero skipped / 35 tests / 2 files; exit 1 |
| Current source with the new recovery-migration exemption      | 33 passed, 2 failed, zero skipped / 35 tests / 2 files; exit 1 |

The archived worktrees did not exactly match the baseline and were not executed.
A temporary fixture was populated from the immutable Git blobs; all 145 test,
source and configuration inputs matched the baseline before and after execution.
The two failure payloads matched exactly:

- `src/schema/revert-to-immich.spec.ts`: the rollback SQL omits the existing
  `1791070000000-AddStackSuppression`, `1791071000000-AddMemoryCandidates` and
  `1793400000000-FixMemoryCandidateSchema` migration names. This inherited
  migration-ledger coverage gap prevents a clean database-revert validation
  claim. Database revert is not a supported rollback path; no rollback was
  executed by these checks.
- `src/utils/shared-space-album-scope.guard.spec.ts`: the static scanner treats
  `memory.repository.ts:22`, the `spaceAlbumAssetExists` line within a multiline
  import, as a module-level asset read. The repository and guard are unchanged
  from the baseline. This is an import-scanner false positive and does not
  demonstrate a runtime scope leak.

## Filesystem alias follow-up

Independent review found that inode and lexical-ancestor checks alone accepted
another owner's bind mount of a descendant of an authorized root. The new
validation compares backing coordinates obtained from the opened directory's
mount identity: `mountRoot` plus its path relative to `mountTarget`. It retains
the lexical and inode guards and invokes the comparison for each existing
other-owner root before publishing a grant.

The focused `authorized-deletion.spec.ts` suite passes all 50 tests. Final server
TypeScript `--noEmit` and scoped ESLint pass. Tests cover the static `A/sub` bind
alias at `B` and at a descendant `B/linked`, in both grant directions,
disjoint local siblings, ambiguous mount coordinates, NFS export overlap across
different device IDs, and disjoint exports on the same configured NFS server
with either equal or different device IDs. Visible nested mounts below other-owner
roots are included, with bounded mountinfo/target inventory; file-bind targets and
unsupported coordinates fail closed.
Different or unresolved NFS server spellings and unequal-device overlay
relationships fail closed. Distinct local and remote NFS devices remain supported.

The validation-caller regression uses real disposable directory descriptors and
distinct inode identities with synthetic `/proc` mount metadata. No privileged
kernel bind mount or actual NFS topology was created or tested. These checks
establish the application-visible mount boundary; they do not prove separation
against privileged NAS export remapping, local self-exports or storage/DNS
administrator changes. The descriptor capture and quarantine unlink logic was
not changed by this alias follow-up and still assumes a controlled filesystem
namespace.

The final three added filesystem error mappings were checked separately: Flutter
26 passed / two files, web 35 passed / four files, with zero failures or skips.
Scoped Dart analysis, web ESLint/TypeScript, Svelte check (zero errors/warnings)
and formatting pass. The web result includes settings, selective actions, Trash
page and Empty Trash tests. The earlier full Flutter result above predates only
these localized-code additions; it was not unnecessarily repeated.

## Client behavior covered

- Missing, invalid, expired or mismatched recovery evidence and changed storage
  roots produce localized guidance on mobile and web. Per-item deletion notices
  use the same error mapping. Unexpected responses keep the generic failure
  message rather than exposing raw server payloads.
- Failed preparation or consent refreshes server policy while preserving the
  original error. A currently unprepared policy cannot be displayed as verified
  merely because its stored consent flag is enabled.
- An owner can revoke existing consent even after the recovery evidence becomes
  invalid. Enabling consent still requires preparation and separate confirmation.
- Administrator preparation sends the existing digest and roots-attestation
  fields. It does not send an owner override, filesystem paths or an external
  grant. HTTP recovery rejection bodies remain available for localized feedback.
- Russian widgets render on a narrow high-DPI screen; tests scroll consent
  controls into view before interacting with long verification text.

Physical S23/iPhone interaction, signed native upgrades and actual storage
deletion were not tested. No production access or writes were performed by these
client checks; device and deployment acceptance remain separate.
