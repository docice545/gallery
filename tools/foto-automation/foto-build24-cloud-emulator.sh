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
for foto_cloud_mode in first restart; do
  adb shell am force-stop de.opennoodle.gallery.debug
  if [[ "$foto_cloud_mode" == restart ]]; then
    foto_shizuku_pid=$(adb shell pidof shizuku_server | tr -d '\r')
    [[ "$foto_shizuku_pid" =~ ^[0-9]+$ ]]
    adb shell kill "$foto_shizuku_pid"
  fi
  python3 tools/foto-automation/foto-build24-cloud-ui.py "$foto_cloud_mode" "$foto_receipts" \
    > "$foto_receipts/cloud-$foto_cloud_mode-ui.log" 2>&1 &
  foto_cloud_ui_pid=$!
  trap 'kill "$foto_cloud_ui_pid" 2>/dev/null || true' EXIT
  if [[ "$foto_cloud_mode" == first ]]; then
    foto_cloud_test=integration_test/sqlite_cloud_media_test.dart
  else
    foto_cloud_test=integration_test/sqlite_cloud_media_restart_test.dart
  fi
  (
    cd mobile
    timeout --signal=TERM --kill-after=20s 20m flutter test --verbose --no-uninstall \
      "$foto_cloud_test" --reporter expanded
  ) 2>&1 | tee "$foto_receipts/cloud-$foto_cloud_mode-test.log"
  wait "$foto_cloud_ui_pid"
  adb exec-out run-as de.opennoodle.gallery.debug cat "app_flutter/cloud24-$foto_cloud_mode-report.json" \
    > "$foto_receipts/cloud-$foto_cloud_mode-report.json"
done
python3 - <<'PY'
import json
for mode in ['first', 'restart']:
    r=json.load(open(f'mobile/ci-receipts/cloud-{mode}-report.json'))
    assert r['sameGeneration'] and r['sameOriginalChecksums'] and r['accountRetained']
    assert r['sqlite']['status']=='ready' and r['backupEnabled'] is False
    assert r['shizukuRunning'] and r['permissionGranted'] and r['selected']
    assert r['pickerQueries']>0 and r['pickerRows']>0
print('PASS: real Shizuku activation/reactivation, picker reads, force-stop/restart; same healthy generation and originals')
PY
