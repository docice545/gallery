#!/usr/bin/env bash
# Must run AFTER the successful Build23->24 upgrade/fresh-start scenario on its AVD.
# Never target a phone or a production package.
set -euo pipefail
[[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]]
[[ "$(adb shell id -u | tr -d '\r')" == 2000 ]]
foto_receipts="$PWD/mobile/ci-receipts"
foto_shizuku="$foto_receipts/shizuku-test.apk"
curl --fail --location --retry 3 --output "$foto_shizuku" \
  https://github.com/RikkaApps/Shizuku/releases/download/v13.6.0/shizuku-v13.6.0.r1086.2650830c-release.apk
printf '%s  %s\n' 6e273ab0e991c4e79bc8b1bbb9b9dd739ccac1a8712a541a214078886b7b790f "$foto_shizuku" | sha256sum --check -
adb install -r "$foto_shizuku"
rm "$foto_shizuku" # test dependency, not a FOTO release artifact
# Build once, then drive this SAME binary twice. flutter test compiles a new
# harness APK per invocation; reinstalling it resets the system picker selection
# and cannot establish the requested force-stop/restart behavior.
(
  cd mobile
  timeout --signal=TERM --kill-after=20s 20m flutter build apk --debug \
    --target-platform android-x64 --target integration_test/sqlite_cloud_media_test.dart
) 2>&1 | tee "$foto_receipts/cloud-build.log"
sha256sum mobile/build/app/outputs/flutter-apk/app-debug.apk > "$foto_receipts/cloud-installed-apk.sha256"
adb install -t -r mobile/build/app/outputs/flutter-apk/app-debug.apk
for foto_cloud_mode in first restart; do
  adb shell am force-stop de.opennoodle.gallery.debug
  if [[ "$foto_cloud_mode" == restart ]]; then
    foto_shizuku_pid=$(adb shell pidof shizuku_server | tr -d '\r')
    [[ "$foto_shizuku_pid" =~ ^[0-9]+$ ]]
    adb shell kill "$foto_shizuku_pid"
  fi
  printf '%s' "$foto_cloud_mode" | adb shell run-as de.opennoodle.gallery.debug tee app_flutter/cloud24-mode >/dev/null
  python3 tools/foto-automation/foto-build24-cloud-ui.py "$foto_cloud_mode" "$foto_receipts" \
    > "$foto_receipts/cloud-$foto_cloud_mode-ui.log" 2>&1 &
  foto_cloud_ui_pid=$!
  trap 'kill "$foto_cloud_ui_pid" 2>/dev/null || true' EXIT
  foto_cloud_vm_url=$(python3 tools/foto-automation/foto-build24-cloud-attach.py)
  (
    cd mobile
    timeout --signal=TERM --kill-after=20s 20m flutter drive --verbose --no-pub \
      --use-existing-app "$foto_cloud_vm_url" \
      --target integration_test/sqlite_cloud_media_test.dart \
      --driver integration_test/test_utils/sqlite_cloud_media_driver.dart --keep-app-running
  ) 2>&1 | tee "$foto_receipts/cloud-$foto_cloud_mode-test.log"
  # A standalone Flutter driver can return success for an empty suite. Require
  # the in-app completion receipt immediately, before waiting on the UI helper.
  adb exec-out run-as de.opennoodle.gallery.debug cat "app_flutter/cloud24-$foto_cloud_mode-report.json" \
    > "$foto_receipts/cloud-$foto_cloud_mode-report.json"
  wait "$foto_cloud_ui_pid"
  adb shell pm path de.opennoodle.gallery.debug > "$foto_receipts/cloud-$foto_cloud_mode-apk-path.txt"
  adb shell dumpsys package de.opennoodle.gallery.debug > "$foto_receipts/cloud-$foto_cloud_mode-installed-package.txt"
done
sha256sum --check "$foto_receipts/cloud-installed-apk.sha256"
python3 - <<'PY'
import json,pathlib,re
root=pathlib.Path('mobile/ci-receipts')
for mode in ['first', 'restart']:
    r=json.load(open(f'mobile/ci-receipts/cloud-{mode}-report.json'))
    assert r['sameGeneration'] and r['sameOriginalChecksums'] and r['accountRetained']
    assert r['sqlite']['status']=='ready' and r['backupEnabled'] is False
    assert r['shizukuRunning'] and r['permissionGranted'] and r['selected'] and r['systemPickerOpened']
    assert r['pickerQueries']>0 and r['pickerRows']>0
assert (root/'cloud-first-apk-path.txt').read_text()==(root/'cloud-restart-apk-path.txt').read_text()
updates=[re.search(r'lastUpdateTime=([^\r\n]+)', (root/f'cloud-{mode}-installed-package.txt').read_text()).group(1) for mode in ['first','restart']]
assert updates[0]==updates[1], 'Restart must not reinstall the APK or reset system picker state'
(root/'cloud-restart-install-report.json').write_text(json.dumps({'sameInstalledApkOnRestart':True,'lastUpdateTime':updates[0]}))
print('PASS: real Shizuku activation/reactivation, picker reads, force-stop/restart; same healthy generation and originals')
PY
