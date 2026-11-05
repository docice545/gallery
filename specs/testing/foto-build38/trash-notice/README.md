# Compact Trash notice and measured controls

Successful reversible Trash uses a compact neutral surface from the active ColorScheme, with `Фото в корзине`, `3 фото в корзине` and a localized `Отменить`. The label is captured before the asynchronous mutation; the action still restores only accepted IDs in the same user/server session. Restore errors use the existing error path. Irreversible/device-only operations never receive a false Undo. Error and unrelated success notifications retain their semantic styling.

The trash selection capsule is again a measured Scaffold footer. Its rounded floating appearance and shared viewer layout are preserved, while the grid and floating notices reserve its actual height, including accessibility labels and system insets. The previous checkpoint's overlay placement covered grid content and notices; two existing layout regressions reproduced this and now pass.

Actual verification: **73 Flutter tests PASS** (new Russian message/Undo tests, existing deletion/consent/session/stack and timeline-footer tests); **4 UI package tests PASS**. The new tests cover both themes, 1/3/21 photos, large text, compact bounds, full localized labels, no English Undo, exact restored IDs and measured-footer clearance. Light and dark synthetic renders were opened and visually reviewed. Their hashes and executed log receipts are recorded here; raw logs stay outside Git.

```sh
cd mobile
FOTO_TRASH_NOTICE_EVIDENCE=/tmp/foto-trash-notice flutter test --no-pub \
  test/presentation/widgets/compact_trash_notice_test.dart \
  test/unit/presentation/actions/delete_action_test.dart \
  test/presentation/widgets/timeline/timeline_with_grouping_pill_test.dart --reporter expanded
cd packages/ui
flutter test --no-pub test/snackbar_test.dart --reporter expanded
```

**DEVICE_REQUIRED:** actual Samsung/iOS notification placement, navigation insets, theme changes, reject/confirm/Undo and error handling against the accepted backend.
