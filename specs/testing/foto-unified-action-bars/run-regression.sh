#!/usr/bin/env bash
set -euo pipefail
repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo_root/mobile"
capture_root="${FOTO_QA_OUTPUT:-/tmp/foto-unified-action-bars}"
flutter test --no-pub \
 test/presentation/widgets/timeline \
 test/presentation/widgets/bottom_sheet \
 test/presentation/widgets/memory \
 test/presentation/widgets/build39_ui_hotfix_test.dart \
 test/presentation/widgets/spaces/space_album_bottom_sheet_test.dart \
 test/presentation/widgets/deletion \
 test/presentation/widgets/images \
 test/presentation/widgets/asset_viewer \
 test/presentation/widgets/icons \
 test/providers/asset_viewer \
 test/utils_legacy/action_button_utils_test.dart \
 test/repositories/asset_media_repository_test.dart \
 test/unit/presentation/actions/google_lens_action_test.dart \
 test/unit/presentation/actions/share_action_test.dart \
 test/unit/presentation/actions/ghost_trap_action_test.dart \
 test/unit/presentation/actions/deletion_snapshot_guard_test.dart \
 test/unit/presentation/actions/delete_action_test.dart \
 test/unit/presentation/actions/local_album_device_deletion_test.dart \
 test/unit/presentation/actions/album_ghost_trap_test.dart \
 "--dart-define=FOTO_UNIFIED_CAPTURE=${capture_root}/after" \
 "--dart-define=FOTO_LENS_CAPTURE=${capture_root}/lens-return" \
 "--dart-define=FOTO_TIMELINE_DELETE_CAPTURE=${capture_root}/timeline-delete" \
 --reporter expanded
