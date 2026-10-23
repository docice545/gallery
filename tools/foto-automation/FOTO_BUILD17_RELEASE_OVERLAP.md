# FOTO Build 17: reviewed partial-overlap integration

## Verified cause

Base: `ace2eab962524479a61e6891410983a7f41ba0fa`.
Editor PR6: `df3e0daf14f7593808a039df080c32cd05a7a503`.
Compatibility PR7: `3cc9631b7a2a48d2889808da5db7a62cc1345fea`.
Release tooling PR8: `4255a4c826fe61f563fb866a139c8044a41eff18` is **not** an application merge input.

`prepare()` first merges the editor into its private worktree. Then
`git cherry HEAD <compatibility> <merge-base>` returns 11 equivalent patches
and 57 new commits. The old implementation rejects every mixed result at
`PARTIALLY_APPLIED_PR_REVIEW_REQUIRED`. Those 11 patches are reviewed shared
storage, metadata and CI fixture fixes, independently committed in both PRs.
Their different commit IDs do not mean duplicate application functionality.

The editor tree is `5102fc271d555b8ab02f35c56cb717f0502aebdc`.
A real `git merge-tree --write-tree` of the exact editor/compatibility heads
produces `09e791c093d10927c434c85787328ebabcace5bd`, without conflicts.
The merged backend, Web, OpenAPI, SDK, migrations and dependency locks match PR7;
the editor files match PR6. This is Git-content evidence, not native-device E2E.

## Narrow admission, not a bypass

`REVIEWED_OVERLAP` applies only to these three exact base/editor/compatibility
SHAs, in the existing editor-then-compatibility order. It requires the current
commit's parents to be exactly base + editor, its tree to match the reviewed
editor tree, and the patch counts to match the reviewed overlap. A read-only
three-way preview must produce the reviewed combined tree.

Only then does the existing full `merge --no-ff` run. No cherry-pick or commit
filtering occurs: both complete histories become ancestors. The actual tree
and merge parents must match the preview before the checkpoint advances.
Mismatch preserves the worktree, merge intent and diagnostic manifest.
Unknown pins, additional/reverted local commits, different trees, conflicts,
dirty worktrees and changed approvals still stop. No operator override flag
or automatic conflict resolution is added.

GitHub/CI gates, locks, rootless endpoint/builder checks, resource limits,
existing-key/certificate validation and artifact hashes remain unchanged.
No production/container/database/media action is part of preparation.

## Resume the existing stopped release

Install the corrected tool in a **new versioned directory**, preserving the old
tool, config, state and manifest snapshots. Use the **same original config**:
do not create new approvals, copy guessed signing settings, edit manifest.json,
reset a worktree or delete locks. `--prepare`/`--resume` rechecks pins and current
CI, verifies the existing private worktree, skips the already merged editor by
ancestry, then reviews and merges the full compatibility history.

This specific STOP occurs before `MERGE_INTENT_compatibility`; it leaves no
compatibility merge in flight. Interrupted real merges remain blocked for review.
Existing test/build receipts from another tool hash cannot be relabelled as
valid: `STAGE_INPUT_CHANGED_NEW_STATE_REQUIRED` preserves them and requires a
separate reviewed state. Do not delete receipts to make resume succeed.

## Verification boundaries

The changed Python orchestration suite initially passed 58 tests (temporary real
Git, mocked external services), including old-checkpoint resume, full-history
merge, idempotency, unknown overlap refusal, changed tree/frontier, preview
conflict, actual-result mismatch, and crash after review/before merge intent.
Later results and published CI are recorded in the PR; a mock is not an HP test.

Already-passed pinned PR6/PR7 suites are retained. Only combined Flutter/editor/
sync regressions need a new cross-PR run; backend/API/migration content has not
changed. Actual rootless builds, signed APK verification, native Android/iOS,
Synology and AI inference require their real environments. No APK or image is
declared complete from orchestration tests or compilation alone.
