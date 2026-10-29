#!/usr/bin/env bash
set -euo pipefail
apk_path=${1:?APK path is required}
version=${2:?version is required}
server_url=${3:?server URL is required}
adb_bin=${ADB_BIN:-adb}
diagnostics_file=${ADB_DIAGNOSTICS_FILE:-/tmp/noodle-android-adb-diagnostics.log}
phase=bootstrap
mark_phase() { phase=$1; echo "phase=$phase" >&2; }
adb_diagnostics() {
  {
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo '--- adb devices ---'
    "$adb_bin" devices -l || true
    echo '--- adb state ---'
    "$adb_bin" get-state || true
    echo '--- emulator properties ---'
    "$adb_bin" shell getprop sys.boot_completed || true
    "$adb_bin" shell getprop ro.kernel.qemu || true
    echo '--- logcat tail ---'
    "$adb_bin" logcat -d -t 200 || true
  } >"$diagnostics_file" 2>&1 || true
}
on_error() {
  rc=$?
  echo "::error title=official Android smoke phase::phase=$phase rc=$rc"
  adb_diagnostics
  return "$rc"
}
trap on_error ERR
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
tap_text_any() {
  local needle
  for needle in "$@"; do
    if tap_text "$needle"; then return 0; fi
  done
  return 1
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
mark_phase wait_for_boot
wait_for_boot
mark_phase install
"$adb_bin" start-server >/dev/null 2>&1 || true
$adb_bin install -r "$apk_path"
mark_phase clear_and_launch
$adb_bin shell pm clear de.opennoodle.gallery >/dev/null
$adb_bin shell monkey -p de.opennoodle.gallery 1 >/tmp/noodle-monkey.log
sleep 5
mark_phase server_endpoint_dump
dump_ui
mark_phase server_endpoint_package
$adb_bin shell dumpsys package de.opennoodle.gallery | grep -q "versionName=$version"
mark_phase server_endpoint_activity
$adb_bin shell dumpsys activity activities | grep -q de.opennoodle.gallery
mark_phase server_endpoint_field
edit_text_at 0 "$server_url"
mark_phase enter_server
tap_text_any 'Next' 'Continue'
mark_phase wait_login
for _ in $(seq 1 30); do sleep 2; dump_ui; grep -qi Email /tmp/noodle-window.xml && break; done
grep -qi Email /tmp/noodle-window.xml
mark_phase credentials
edit_text_at 0 'admin@immich.cloud'
edit_text_at 1 'password'
tap_text_any 'Login' 'Log in'
sleep 12
mark_phase authenticated
dump_ui
$adb_bin shell dumpsys activity activities | grep -q de.opennoodle.gallery
$adb_bin shell screencap -p /sdcard/noodle-$version.png
$adb_bin pull /sdcard/noodle-$version.png "${ARTIFACT_DIR:-/tmp}/noodle-$version.png" >/dev/null
mark_phase complete
trap - ERR
echo "Noodle Gallery $version installed, authenticated, and foreground on disposable backend."

