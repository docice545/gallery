> Исторический checkpoint; актуальная передача: [BUILD11_CLOUD_HANDOFF.md](../BUILD11_CLOUD_HANDOFF.md).

# Build11 release tooling progress

Branch: `candidate/gallery-5.7.3-build11-upstream`; application development is
uncommitted until the coordinating agent finishes combined validation.

Implemented in this workstream:

- Existing image-only core remains strict by default. Explicit checksum-pinned
  Build11 compatibility receipt permits only unchanged old migration bytes plus
  `1794050000000-OwnerStorageDeletion`, with pinned actual guard/image/source proofs
  and mandatory real isolated rollback runtime/Trash/Restore evidence.
- Distinct hardened fallback remains verifiable after a recorded rollback;
  unrecorded/replaced fallback containers remain rejected.
- Schema3 Build11 artifact seal checks same-source successful existing workflow
  runs, full archive layers, APK package/signature and unsigned IPA extensions.
- Compiled package assembler and checksum-first installer/upgrade/verify/rollback
  entrypoints reuse existing tooling. No source compilation is required on HP.
- Existing exact-six cleanup is separately gated and idempotent; completed
  receipts/physical absence are reused. The remaining 21 jobs are exact and paused.
- Fresh SQL/gzip backup and exact isolated restoration reuse established functions;
  optional Build11 transition hook preserves the legacy default behavior.
- HP-only signing wrapper reuses existing key and compiled CI payload, separately
  approved; no production key is read in this cloud environment.

Executed here so far: 73 existing image-release tests PASS; 9 reviewed Build11
rollback tests PASS; 7 profile/package tests PASS. Sign-wrapper and upgraded-copy
tests are delegated separately. Syntax and combined focused tooling checks must
be rerun after the coordinating agent's final changes. No production execution,
Docker/APK/IPA release build or signing was performed by this workstream.

Open gates: actual successful same-source CI artifacts; real isolated old-image
HTTP startup/storage-grant refusal/Trash/Restore after upgrade; exact HP fresh
restored-copy/NAS evidence; completed six cleanup receipt (current HP not assumed
deployed); clean Ubuntu installer physical execution; S23/iPhone acceptance.
Global backgroundTask remains paused: automatic expiration/queued cleanup is not
claimed operational until a separate safe queue activation plan is approved.

Next: run focused Python suites and shell syntax; regenerate existing Build10
tooling manifests after final core changes; seal real successful artifacts; create
compatibility receipt only from actual passing image-level reports; assemble
binary package; supply immutable checksums/run links. Do not synthesize PASS or
deploy. Preserve all existing evidence and review branches.
