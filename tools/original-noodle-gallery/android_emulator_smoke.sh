#!/usr/bin/env bash
set -euo pipefail
apk_path=${1:?APK path is required}
version=${2:?version is required}
server_url=${3:?server URL is required}
adb_bin=${ADB_BIN:-adb}
wait_for_boot() {
  for _ in $(seq 1 90); do
    if [[ "$($adb_bin get-state 2>/dev/null || true)" == "device" ]] && [[ "$($adb_bin shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then return 0; fi
    sleep 2
  done
  return 1
}
dump_ui() {
  $adb_bin shell uiautomator dump /sdcard/window.xml >/dev/null
  $adb_bin shell cat /sdcard/window.xml | tr -d '\r' > /tmp/noodle-window.xml
}
find_bounds() {
  python3 - "$1" /tmp/noodle-window.xml <<'PY'
import sys
import xml.etree.ElementTree as ET
needle = sys.argv[1].lower()
for node in ET.parse(sys.argv[2]).getroot().iter('node'):
    text = ' '.join((node.attrib.get(k) or '') for k in ('text', 'content-desc', 'resource-id')).lower()
    if needle in text and node.attrib.get('bounds'):
        print(node.attrib['bounds']); break
PY
}
center() {
  python3 - "$1" <<'PY'
import re, sys
m = re.findall(r'\[(\d+),(\d+)\]', sys.argv[1])
if len(m) != 2:
    raise SystemExit(f'Unable to parse UI bounds: {sys.argv[1]!r}')
print((int(m[0][0]) + int(m[1][0])) // 2, (int(m[0][1]) + int(m[1][1])) // 2)
PY
}
tap_text() {
  local b x y
  b=$(find_bounds "$1")
  test -n "$b" || { echo "UI element not found: $1" >&2; return 1; }
  read -r x y < <(center "$b")
  $adb_bin shell input tap "$x" "$y"
}
edit_text_at() {
  local i=$1 value=$2 b x y
  b=$(python3 - "$i" /tmp/noodle-window.xml <<'PY'
import sys
import xml.etree.ElementTree as ET
items = [n for n in ET.parse(sys.argv[2]).getroot().iter('node') if n.attrib.get('class') == 'android.widget.EditText']
print(items[int(sys.argv[1])].attrib['bounds'])
PY
)
  read -r x y < <(center "$b")
  $adb_bin shell input tap "$x" "$y"
  $adb_bin shell input text "$value"
}
wait_for_boot
$adb_bin install -r "$apk_path"
$adb_bin shell pm clear de.opennoodle.gallery >/dev/null
$adb_bin shell monkey -p de.opennoodle.gallery 1 >/tmp/noodle-monkey.log
sleep 5
dump_ui
$adb_bin shell dumpsys package de.opennoodle.gallery | grep -q "versionName=$version"
$adb_bin shell dumpsys activity activities | grep -q de.opennoodle.gallery
tap_text 'Server Endpoint URL'
edit_text_at 0 "$server_url"
tap_text 'Next'
for _ in $(seq 1 30); do sleep 2; dump_ui; grep -qi Email /tmp/noodle-window.xml && break; done
grep -qi Email /tmp/noodle-window.xml
edit_text_at 0 'admin@immich.cloud'
edit_text_at 1 'password'
tap_text 'Login'
sleep 12
dump_ui
$adb_bin shell dumpsys activity activities | grep -q de.opennoodle.gallery
$adb_bin shell screencap -p /sdcard/noodle-$version.png
$adb_bin pull /sdcard/noodle-$version.png "${ARTIFACT_DIR:-/tmp}/noodle-$version.png" >/dev/null
echo "Noodle Gallery $version installed, authenticated, and foreground on disposable backend."

