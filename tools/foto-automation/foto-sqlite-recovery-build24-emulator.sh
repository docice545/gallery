#!/usr/bin/env bash
# Synthetic debug-package emulator test only. Never target a production device.
set -euo pipefail
[[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]]
foto_mode=${1:?upgrade or checkpoint}
case "$foto_mode" in
  upgrade) foto_test=integration_test/sqlite_build24_upgrade_test.dart ;;
  checkpoint) foto_test=integration_test/sqlite_build24_checkpoint_test.dart ;;
  *) exit 2 ;;
esac
export FOTO24_TEST_MODE="$foto_mode"
mkdir -p mobile/ci-receipts
if [[ "$foto_mode" == upgrade ]]; then
  (
    cd build23-baseline/mobile
    timeout --signal=TERM --kill-after=20s 20m flutter test --verbose --no-uninstall \
      integration_test/build23_upgrade_fixture.dart --reporter expanded
  ) 2>&1 | tee mobile/ci-receipts/android-build23-fixture.log
  # A real app process death, followed by APK replacement; no clear/uninstall.
  adb shell am force-stop de.opennoodle.gallery.debug
  adb shell pm grant de.opennoodle.gallery.debug android.permission.READ_MEDIA_IMAGES
  adb shell pm grant de.opennoodle.gallery.debug android.permission.READ_MEDIA_VIDEO
fi
adb logcat -v threadtime > mobile/ci-receipts/emulator-${foto_mode}-logcat.log 2>&1 &
foto_logcat_pid=$!
python3 - <<'PY' > mobile/ci-receipts/saf-${foto_mode}-picker.log 2>&1 &
import os, re, subprocess, time, xml.etree.ElementTree as ET
saved = 0
expected = 2 if os.environ["FOTO24_TEST_MODE"] == "upgrade" else 1
end = time.monotonic() + 1800
while time.monotonic() < end:
    focus = subprocess.run(['adb','shell','dumpsys','window','windows'],capture_output=True,text=True,timeout=10).stdout
    if 'documentsui' in focus.lower():
        subprocess.run(['adb','shell','uiautomator','dump','/sdcard/foto24-picker.xml'],stdout=subprocess.DEVNULL,timeout=15)
        xml = subprocess.run(['adb','shell','cat','/sdcard/foto24-picker.xml'],capture_output=True,text=True,timeout=10).stdout
        try:
            for node in ET.fromstring(xml).iter('node'):
                if node.get('enabled') != 'true': continue
                if node.get('text','').lower() != 'save' and not node.get('resource-id','').endswith(':id/action_menu_save'): continue
                bounds = list(map(int,re.findall(r'\d+',node.get('bounds',''))))
                if len(bounds) != 4: continue
                x1,y1,x2,y2 = bounds
                subprocess.run(['adb','shell','input','tap',str((x1+x2)//2),str((y1+y2)//2)],check=True,timeout=10)
                print('Selected Save in Android DocumentsUI',flush=True)
                saved += 1
                if saved == expected: raise SystemExit(0)
                time.sleep(3)
                break
        except ET.ParseError:
            pass
    time.sleep(1)
raise SystemExit('SAF picker did not appear')
PY
foto_picker_pid=$!
foto_emulator_cleanup() {
  kill "$foto_picker_pid" 2>/dev/null || true
  kill "$foto_logcat_pid" 2>/dev/null || true
  # This emulator contains only the synthetic debug fixture. Retain diagnostics
  # on timeout/failure as well as success; never run against a real phone.
  timeout 10s adb logcat -b crash -d > mobile/ci-receipts/emulator-${foto_mode}-crashes.log 2>&1 || true
}
trap foto_emulator_cleanup EXIT
(
  cd mobile
  # Bound build + VM-service connection too: testWidgets' timeout starts only
  # after Dart connects and cannot catch an Android launch failure.
  timeout --signal=TERM --kill-after=20s 20m flutter test --verbose --no-uninstall \
    "$foto_test" --reporter expanded
) 2>&1 | tee mobile/ci-receipts/android-${foto_mode}.log
wait "$foto_picker_pid"
adb pull /sdcard/Download/FOTO-SQLite-backup.zip mobile/ci-receipts/synthetic-${foto_mode}-recovery.zip
python3 - <<'PY'
import hashlib,json,zipfile,os
with zipfile.ZipFile('mobile/ci-receipts/synthetic-'+os.environ['FOTO24_TEST_MODE']+'-recovery.zip') as z:
    assert z.testzip() is None
    report=json.loads(z.read('export-report.json'))
    for name,digest in report['sourceChecksums'].items():
        assert hashlib.sha256(z.read('source/'+name)).hexdigest() == digest
    assert any(n.endswith('immich.sqlite-wal') and z.getinfo(n).file_size > 32 for n in z.namelist())
    attempts=[json.loads(z.read(n)) for n in z.namelist() if n.endswith('recovery-report.json')]
    assert report['format']==24
    if os.environ['FOTO24_TEST_MODE']=='upgrade':
        assert any(r['format']==23 and r['outcome']=='missing_or_unprovable_wal' and r['tablesChecked']==0 for r in attempts)
        assert any(r['format']==24 and r['outcome']=='empty_wal_evidence_missing' and r['tablesChecked']>50 for r in attempts)
        assert not any(r['outcome']=='validated' for r in attempts)
        assert hashlib.sha256(z.read('source/immich.sqlite-shm')).hexdigest()=='fd4c9fda9cd3f9ae7c962b0ddf37232294d55580e1aa165aa06129b8549389eb'
        assert z.read('source/immich.sqlite-wal')==b''
        assert any(n.endswith('server-view-report.json') for n in z.namelist())
    else:
        assert any(r['format']==24 and r['outcome']=='validated' and r['contentMatch'] and r['tablesChecked']>50 and r['walEvidence']['code']=='checkpoint_with_matching_wal_snapshot' for r in attempts)
print('PASS: Build24 '+os.environ['FOTO24_TEST_MODE']+', real SAF ZIP, exact source checksums and retained historical WAL')
PY

if [[ "$foto_mode" == upgrade ]]; then
  adb pull /sdcard/Download/FOTO-before-new-start.zip mobile/ci-receipts/synthetic-before-new-start.zip
  python3 - <<'PYZIP'
import hashlib,zipfile
with zipfile.ZipFile('mobile/ci-receipts/synthetic-before-new-start.zip') as z:
    assert z.testzip() is None
    assert hashlib.sha256(z.read('source/immich.sqlite-shm')).hexdigest()=='fd4c9fda9cd3f9ae7c962b0ddf37232294d55580e1aa165aa06129b8549389eb'
    assert z.read('source/immich.sqlite-wal')==b''
    assert any(n.startswith('build22-recovery/') and n.endswith('immich.sqlite-wal') and z.getinfo(n).file_size>32 for n in z.namelist())
print('PASS: separate verified external ZIP retained before consented fresh start')
PYZIP
fi
