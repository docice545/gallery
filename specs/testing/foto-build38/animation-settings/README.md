# Persistent deletion-effect preference

Settings → Interface → Animations contains **Эффектное удаление**, enabled by default. The existing settings repository persists `animationFancyDeletion` by name; no database schema or deletion protocol changes. All ten maintained locales are updated.

The stable ghost coordinator observes the preference on its first use. Off prevents capture, source holds and flight overlays; existing confirmed operations update their grids normally. Switching off cancels only transient pixels, including an in-progress capture or flight. It never grants success, cancels a mutation, suppresses consent or retries deletion. Switching on applies to the next action without restarting. System reduced motion retains the existing short fade instead of the special flight.

Actual Flutter 3.47.2 validation on 2026-11-05: **126 PASS** across settings persistence, configuration, coordinator single/batch and reduced-motion matrices, live changes, exact deletion IDs, confirmation/cancellation/Undo and album cleanup. The separate visual run is **3 PASS**; all **22** regenerated bin-animation PNGs are byte-identical to the previously reviewed [trash-eats frames](../trash-eats/README.md). No animation geometry was replaced.

The four PNGs here are synthetic widget renders, opened and reviewed in both themes and both states; they are not device screenshots. `receipts.json` records their hashes and the executed log hashes. Raw logs remain outside Git.

```sh
cd mobile
export PATH=/path/to/flutter-3.47.2/bin:$PATH
FOTO_ANIMATION_SETTINGS_EVIDENCE=/tmp/foto-animation-settings flutter test --no-pub \
  test/widgets/settings/animation_setting_test.dart \
  test/medium/repositories/settings_repository_test.dart \
  test/domain/models/config/app_config_test.dart \
  test/presentation/widgets/deletion \
  test/unit/presentation/actions/delete_action_test.dart \
  test/unit/presentation/actions/local_album_cleanup_action_test.dart \
  test/unit/presentation/actions/album_ghost_trap_test.dart --reporter expanded
```

**DEVICE_REQUIRED:** on Samsung and iOS, toggle both modes, restart the app, delete one and several disposable photos, reject device consent and permanent deletion once, exercise Undo, enable system reduced motion, and verify the actual display and haptic behavior. Signed-package installation remains separate acceptance work.
