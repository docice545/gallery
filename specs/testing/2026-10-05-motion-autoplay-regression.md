# Samsung timeline autoplay correction

Baseline: `a1ab0826ab266ea6ad09f19ab9288805b606eab2`. The owner physically
verified build 5.7.2+3: sharp timeline stills, but no Live/Motion autoplay.

The new presentation gate compared native motion dimensions/aspect with the
original still and the tile's high-DPI still requirement. Real paired camera
resources need not have equal aspect or enough pixels for that still target.
Rejecting a valid pair completed the settled viewport's one-shot reservation
before `play()`. It did not indicate that the pair or its authenticated source
was missing.

The correction accepts valid positive finite native geometry without requiring
pixel parity. A tile-sized, clipped cover surface gives the native aspect-fitting
player its actual motion aspect while keeping the existing still canvas and
face-aware alignment. No new player, prefetch, original request or autoplay
selector is introduced. Source camera field-of-view differences cannot be
spatially registered without metadata; physical acceptance must check these.

The still request/decode policy is unchanged: tile × DPR, source aspect-aware,
1440-pixel long-side bound, thumbnail/preview selection, and face union/contain
fallback. A short motion component can inherently contain fewer pixels; after
completion or cancellation the sharp still returns. Invalid/missing native
geometry still consumes only the selected reservation and remains static.

Autoplay remains 80% visible, 350ms settled, muted, one-shot, non-looping, one
active controller, no cascade, and cancelled by scrolling/navigation/disposal.
The Flutter correction applies to Android and iOS. Linux widget tests do not
prove Samsung decoding or AVPlayer orientation/HDR behavior.

## Owner-run APK verification on HP

Cloud has neither the Android SDK nor the existing `foto` release key. Do not
build a debug-signed substitute, generate a key, or copy signing secrets to Git.
The application version is now 5.7.2+4. These commands do not rebuild the server
or touch Takeout/auto-stack:

```bash
# Проверить checkout и сохранить любую существующую локальную работу.
cd /opt/gallery-fork
git status --short
git rev-parse HEAD
# При непустом status не выполнять pull/restore автоматически: сначала
# сохранить и сопоставить локальные Takeout/pubspec изменения с origin/work.
git fetch origin work
# Выполнить только после проверки локальных изменений и возможности fast-forward.
git merge --ff-only origin/work
cd mobile

# Никаких изменений существующего key.jks/key.properties/alias foto.
test -s android/key.jks
test -f android/key.properties

# После финальных iOS/shared изменений нужны новые ignored Pigeon/Freezed outputs.
# Использовать существующий Flutter-aware codegen; версии из lock не обновлять.
flutter pub get --enforce-lockfile
pigeon_main="$(python3 - <<'PY'
import json
from pathlib import Path
from urllib.parse import urljoin, urlparse, unquote
config = Path('.dart_tool/package_config.json').resolve()
package = next(p for p in json.loads(config.read_text())['packages'] if p['name'] == 'pigeon')
uri = urlparse(urljoin(config.as_uri(), package['rootUri']))
if uri.scheme != 'file':
    raise SystemExit('Pigeon must resolve to a local locked package')
print(Path(unquote(uri.path)) / 'bin/pigeon.dart')
PY
)"
for definition in pigeon/*.dart; do
  dart --packages=.dart_tool/package_config.json "$pigeon_main" --input "$definition"
done
dart format lib/platform/
flutter pub run easy_localization:generate -S ../i18n
flutter pub run bin/generate_keys.dart
# Только генерация mobile-кода; production DB migrations не выполняются.
flutter pub run drift_dev make-migrations
flutter pub run drift_dev schema generate --data-classes --companions \
  drift_schemas/main/ test/drift/main/generated/
flutter pub run build_runner build
dart format lib/routing/router.gr.dart
flutter analyze
flutter build apk --release --build-name=5.7.2 --build-number=4

# Проверить идентификатор, версию и постоянную подпись; пароли не печатаются.
"$HOME/Android/Sdk/build-tools/36.0.0/aapt" dump badging \
  build/app/outputs/flutter-apk/app-release.apk
"$HOME/Android/Sdk/build-tools/36.0.0/apksigner" verify --verbose --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
sha256sum build/app/outputs/flutter-apk/app-release.apk
```

Expected applicationId: `de.opennoodle.gallery`; versionName `5.7.2`,
versionCode `4`; certificate SHA-256
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
APK path: `/opt/gallery-fork/mobile/build/app/outputs/flutter-apk/app-release.apk`.
This is an expected owner-build path, not a Cloud-produced artifact.

Acceptance: check landscape/portrait Samsung pairs, a large high-DPI single row,
face crop, scrolling, one-shot/no-cascade, still sharpness before/after, autoplay
off, navigation and reopening. Motion may have a different inherent camera crop;
verify no tile resize/letterbox jump and correct source orientation.
