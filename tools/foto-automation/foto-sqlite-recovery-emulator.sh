#!/usr/bin/env bash
# Synthetic debug-package emulator test only. Never target a production device.
set -euo pipefail
[[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]]
mkdir -p mobile/ci-receipts
python3 - <<'PY' > mobile/ci-receipts/saf-picker.log 2>&1 &
import re, subprocess, time, xml.etree.ElementTree as ET
end = time.monotonic() + 1800
while time.monotonic() < end:
    focus = subprocess.run(['adb','shell','dumpsys','window','windows'],capture_output=True,text=True,timeout=10).stdout
    if 'documentsui' in focus.lower():
        subprocess.run(['adb','shell','uiautomator','dump','/sdcard/foto23-picker.xml'],stdout=subprocess.DEVNULL,timeout=15)
        xml = subprocess.run(['adb','shell','cat','/sdcard/foto23-picker.xml'],capture_output=True,text=True,timeout=10).stdout
        try:
            for node in ET.fromstring(xml).iter('node'):
                if node.get('enabled') != 'true': continue
                if node.get('text','').lower() != 'save' and not node.get('resource-id','').endswith(':id/action_menu_save'): continue
                bounds = list(map(int,re.findall(r'\d+',node.get('bounds',''))))
                if len(bounds) != 4: continue
                x1,y1,x2,y2 = bounds
                subprocess.run(['adb','shell','input','tap',str((x1+x2)//2),str((y1+y2)//2)],check=True,timeout=10)
                print('Selected Save in Android DocumentsUI',flush=True)
                raise SystemExit(0)
        except ET.ParseError:
            pass
    time.sleep(1)
raise SystemExit('SAF picker did not appear')
PY
foto_picker_pid=$!
trap 'kill "$foto_picker_pid" 2>/dev/null || true' EXIT
(
  cd mobile
  flutter test integration_test/sqlite_one_tap_recovery_test.dart --reporter expanded
) 2>&1 | tee mobile/ci-receipts/android-one-tap.log
wait "$foto_picker_pid"
adb pull /sdcard/Download/FOTO-SQLite-backup.zip mobile/ci-receipts/synthetic-recovery.zip
python3 - <<'PY'
import hashlib,json,zipfile
with zipfile.ZipFile('mobile/ci-receipts/synthetic-recovery.zip') as z:
    assert z.testzip() is None
    report=json.loads(z.read('export-report.json'))
    for name,digest in report['sourceChecksums'].items():
        assert hashlib.sha256(z.read('source/'+name)).hexdigest() == digest
    assert any(n.endswith('immich.sqlite-wal') and z.getinfo(n).file_size > 32 for n in z.namelist())
    attempts=[json.loads(z.read(n)) for n in z.namelist() if n.endswith('recovery-report.json')]
    assert any(r['outcome']=='validated' and r['contentMatch'] and r['tablesChecked'] >= 4 for r in attempts)
print('PASS: real SAF ZIP, checksums, retained WAL, validated table report')
PY
