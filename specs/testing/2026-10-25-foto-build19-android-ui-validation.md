# FOTO Build 19: Android editor and Trash validation

Build 19's existing Android Live Photo implementation is retained. This change
only adjusts editor controls, copy-save entry and measured timeline UI geometry.

## Result and protection boundaries

- Save offers the existing copy export directly. The disabled replace action and
  long format/storage explanation are removed. Duplicate taps cannot start two
  exports. Cancellation, retry and denied native save retain the edited document.
  Tests verify source pixels and the original save callback remain untouched.
- The mode bar is 56 px, the drawing strip 48 px, and expanded settings use less
  viewport space. The tool picker has wrapped distinct labels, a 48 px target and
  a bounded scrollable popup. Arrow/Rectangle/Ellipse are translated in English
  and all nine required locales. Undo/redo and all drawing modes remain tested.
- Trash uses an opt-in measured grouping footer and measured selection bar
  inside Scaffold. Floating snackbars clear that space. Menu notifications use
  the existing ToastService. Long results retain their full text in a bounded
  scrollable notification. Wide date strings flex and truncate visually with the
  full date available through tooltip/semantics instead of overflowing.

Deletion, restoration, permanent-delete authorization, external-library original
protection, export destination and backup behavior are unchanged. Tests use
synthetic images and mocked/in-memory services, never user media or production.

## Checks completed

- Four editor suites: **99 passed** while intentionally updating goldens.
- Final combined Android widget/unit regression, without updating goldens:
  **304 passed, 0 failed, 1 existing map-theme skip** in 25 files. This covers the
  editor, Trash actions/layout/notifications, Places/map, location permissions and
  the existing Live Photo controller/scope/thumbnail tests.
- Full Flutter analyze: **No issues found**.
- Android `:app:testDebugUnitTest`: **71 passed, 0 failures/errors/skips** across
  eight suites, including native compilation and the new place-name policy.
- Dart format and `git diff --check` pass.

Exact test invocation and machine-readable/native results are retained with the
session artifacts. Earlier layout failures exposed the real long-date overflow;
old 64 px editor expectations were updated to the required compact upper bound
while retaining the minimum 48 px touch target. Test wrappers now load real
translations and provide Material, matching the actual app environment.

## Visual and release limits

Editor goldens under `mobile/test/pages/edit/goldens/` include Russian portrait,
landscape, large text, collapsed drawing controls and the expanded tool menu.
They were visually inspected. They are Flutter test renders of a synthetic color
chart, **not emulator or Samsung screenshots**. This environment has neither an
Android emulator binary/system image nor `/dev/kvm`; no physical-device claim is
made. One UI gesture navigation, keyboard and system font behavior still need
device acceptance.

Android remains `de.opennoodle.gallery`, version `5.7.3+19`. Existing signing
configuration and production APKs are unchanged. Cloud signing is not evidence
of the HP production certificate. A new unsigned compilation candidate must not
be installed or described as a signed release. Use the existing local HP key and
certificate/update checks in the Build 19 Android validation handoff; never
generate or substitute a key. No automatic installation or deployment is part of
this change.
