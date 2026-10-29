#!/usr/bin/env bash
set -euo pipefail
apk_path=${1:?APK path is required}
version=${2:?version is required}
server_url=${3:?server URL is required}
adb_bin=${ADB_BIN:-adb}
package_name=${PACKAGE_NAME:-de.opennoodle.gallery.debug}
artifact_dir=${ARTIFACT_DIR:-/tmp/foto-offline-e2e}
diagnostics_file=${ADB_DIAGNOSTICS_FILE:-$artifact_dir/adb-diagnostics.log}
phase=bootstrap
mark_phase() { phase=$1; echo "phase=$phase" >&2; }
ui_summary() {
  python3 - <<'PY'
import xml.etree.ElementTree as ET
try:
    root = ET.parse('/tmp/noodle-window.xml').getroot()
except Exception:
    raise SystemExit(0)
rows = []
for node in root.iter('node'):
    values = [node.attrib.get(k, '') for k in ('text', 'content-desc', 'resource-id', 'class')]
    if any(values[:3]): rows.append('|'.join(values))
print(' || '.join(rows)[:3500])
PY
}
mkdir -p "$artifact_dir"
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
  ui=''
  if [[ -s /tmp/noodle-window.xml ]]; then ui=$(ui_summary); fi
  echo "::error title=FOTO offline smoke phase::phase=$phase rc=$rc ui=$ui"
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
nodes = list(ET.parse(sys.argv[2]).getroot().iter('node'))
def label(node):
    return ' '.join((node.attrib.get(k) or '') for k in ('text', 'content-desc')).strip().lower()
for exact_button in (True, False):
    for node in nodes:
        value = label(node)
        klass = (node.attrib.get('class') or '').lower()
        is_button = ('button' in klass or node.attrib.get('clickable') == 'true') and node.attrib.get('enabled', 'true') != 'false'
        if node.attrib.get('bounds') and (value == needle if exact_button else needle in value) and (not exact_button or is_button):
            print(node.attrib['bounds']); raise SystemExit(0)
for node in nodes:
    value = ' '.join((node.attrib.get(k) or '') for k in ('text', 'content-desc', 'resource-id')).lower()
    if needle in value and node.attrib.get('bounds'):
        print(node.attrib['bounds']); break
PY
}
find_action_bounds() {
  python3 - "$1" /tmp/noodle-window.xml <<'PY'
import sys
import xml.etree.ElementTree as ET

needle = sys.argv[1].strip().casefold()
root = ET.parse(sys.argv[2]).getroot()
for node in root.iter('node'):
    if node.attrib.get('enabled', 'true').casefold() != 'true':
        continue
    if node.attrib.get('clickable', 'false').casefold() != 'true':
        continue
    if not node.attrib.get('bounds'):
        continue
    klass = (node.attrib.get('class') or '').casefold()
    if 'button' not in klass:
        continue
    labels = [
        (node.attrib.get('text') or '').strip().casefold(),
        (node.attrib.get('content-desc') or '').strip().casefold(),
        (node.attrib.get('resource-id') or '').strip().casefold(),
    ]
    if needle in labels:
        print(node.attrib['bounds'])
        break
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
tap_action_text() {
  local b x y
  b=$(find_action_bounds "$1")
  test -n "$b" || { echo "Enabled clickable button not found: $1" >&2; return 1; }
  read -r x y < <(center "$b")
  $adb_bin shell input tap "$x" "$y"
}
tap_action_text_any() {
  local needle
  for needle in "$@"; do
    if tap_action_text "$needle"; then return 0; fi
  done
  return 1
}
edit_text_count_at_least() {
  local count=$1
  python3 - "$count" /tmp/noodle-window.xml <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[2]).getroot()
items = []
for node in root.iter('node'):
    klass = (node.attrib.get('class') or '').casefold()
    input_type = (node.attrib.get('input-type') or '').casefold()
    if ('edittext' in klass or input_type not in ('', 'none', '0')) and node.attrib.get('bounds'):
        if node.attrib.get('enabled', 'true').casefold() == 'true':
            items.append(node)
raise SystemExit(0 if len(items) >= int(sys.argv[1]) else 1)
PY
}
focused_edit_text() {
  local bounds=$1
  python3 - "$bounds" /tmp/noodle-window.xml <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[2]).getroot()
for node in root.iter('node'):
    if node.attrib.get('bounds') == sys.argv[1] and node.attrib.get('focused', 'false').casefold() == 'true':
        raise SystemExit(0)
raise SystemExit(1)
PY
}
clear_focused_edit_text() {
  # MOVE_END followed by a bounded delete sequence clears a stale endpoint or
  # autofilled credential without guessing coordinates or relying on clipboard.
  local deletes
  printf -v deletes ' 67%.0s' {1..128}
  $adb_bin shell input keyevent 123$deletes
}
read_edit_text_at() {
  python3 - "$1" /tmp/noodle-window.xml <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[2]).getroot()
items = []
for node in root.iter('node'):
    klass = (node.attrib.get('class') or '').casefold()
    input_type = (node.attrib.get('input-type') or '').casefold()
    if ('edittext' in klass or input_type not in ('', 'none', '0')) and node.attrib.get('bounds'):
        if node.attrib.get('enabled', 'true').casefold() == 'true':
            items.append(node)
index = int(sys.argv[1])
if index < len(items):
    print(items[index].attrib.get('text', ''))
PY
}
set_edit_text() {
  local i=$1 value=$2 b x y timeout=${UI_WAIT_SECONDS:-90}
  for attempt in 1 2 3; do
    b=$(wait_for_edit_text "$i")
    read -r x y < <(center "$b")
    $adb_bin shell input tap "$x" "$y"
    for _ in $(seq 1 20); do
      dump_ui || true
      if focused_edit_text "$b"; then break; fi
      sleep 0.25
    done
    clear_focused_edit_text
    # Send the complete value only after the focused state is observable. The
    # readback catches Flutter's first-character loss and retries from empty.
    $adb_bin shell input text "$value"
    # Password fields are intentionally masked in the accessibility tree, so
    # verify the observable text only for the endpoint/email field.
    if [[ "$i" != 0 ]]; then
      sleep 1
      return 0
    fi
    for _ in $(seq 1 20); do
      sleep 0.25
      dump_ui || true
      if [[ "$(read_edit_text_at "$i")" == "$value" ]]; then return 0; fi
    done
    echo "Input readback mismatch at index $i (attempt $attempt; expected=$value actual=$(read_edit_text_at "$i"))" >&2
  done
  echo "Failed to set EditText index $i with verified readback" >&2
  return 1
}
edit_text_at() {
  local i=$1 value=$2
  set_edit_text "$i" "$value"
}
wait_for_edit_text() {
  local i=$1 timeout=${UI_WAIT_SECONDS:-90} b
  for _ in $(seq 1 "$timeout"); do
    dump_ui || true
    if b=$(python3 - "$i" /tmp/noodle-window.xml <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[2]).getroot()
items = []
for node in root.iter('node'):
    klass = (node.attrib.get('class') or '').lower()
    input_type = (node.attrib.get('input-type') or '').lower()
    if ('edittext' in klass or input_type not in ('', 'none', '0')) and node.attrib.get('bounds'):
        items.append(node)
index = int(sys.argv[1])
if index < len(items):
    print(items[index].attrib['bounds'])
    raise SystemExit(0)
raise SystemExit(1)
PY
    ); then
      printf '%s\n' "$b"
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for EditText index $i (phase=$phase)" >&2
  ui_summary >&2 || true
  return 1
}
mark_phase wait_for_boot
wait_for_boot
mark_phase install
"$adb_bin" start-server >/dev/null 2>&1 || true
$adb_bin install -r "$apk_path"
mark_phase clear_and_launch
$adb_bin shell pm clear "$package_name" >/dev/null
$adb_bin shell monkey -p "$package_name" 1 >"$artifact_dir/launch.log"
sleep 5
mark_phase server_endpoint_dump
dump_ui
mark_phase server_endpoint_activity
$adb_bin shell dumpsys activity activities | grep -q "$package_name"
mark_phase server_endpoint_field
edit_text_at 0 "$server_url"
mark_phase enter_server_submit
if ! tap_action_text_any 'Next' 'Continue'; then
  # The endpoint TextField advertises IME_ACTION_NEXT; retain the semantic
  # keyboard submission as a fallback for Flutter builds that omit the button
  # from the Android hierarchy.
  $adb_bin shell input keyevent 66
fi
sleep 1
dump_ui
mark_phase wait_login
has_login_fields() {
  python3 - <<'PY'
import xml.etree.ElementTree as ET
root = ET.parse('/tmp/noodle-window.xml').getroot()
fields = []
for node in root.iter('node'):
    klass = (node.attrib.get('class') or '').lower()
    input_type = (node.attrib.get('input-type') or '').lower()
    if ('edittext' in klass or input_type not in ('', 'none', '0')) and node.attrib.get('bounds'):
        if node.attrib.get('enabled', 'true').casefold() == 'false':
            continue
        fields.append(node)
print('yes' if len(fields) >= 2 else 'no')
PY
}
login_opened=false
for _ in $(seq 1 30); do
  sleep 2
  dump_ui
  if grep -qi Email /tmp/noodle-window.xml || [[ "$(has_login_fields)" == yes ]]; then break; fi
  if [[ "$login_opened" == false ]] && tap_action_text_any 'Login' 'Log in'; then
    login_opened=true
    $adb_bin shell input keyevent 66 || true
  fi
done
grep -qi Email /tmp/noodle-window.xml || [[ "$(has_login_fields)" == yes ]]
mark_phase credentials
edit_text_at 0 'admin@immich.cloud'
edit_text_at 1 'password'
tap_action_text_any 'Login' 'Log in'
sleep 12
mark_phase authenticated
dump_ui
$adb_bin shell dumpsys activity activities | grep -q de.opennoodle.gallery
for _ in $(seq 1 30); do
  grep -Eq '2020|2024' /tmp/noodle-window.xml && break
  sleep 2
  dump_ui
done
grep -Eq '2020|2024' /tmp/noodle-window.xml
$adb_bin shell screencap -p /sdcard/foto-online.png
$adb_bin pull /sdcard/foto-online.png "$artifact_dir/online.png" >/dev/null

assert_rendered_capture() {
  local file=$1 colors
  test -s "$file"
  command -v identify >/dev/null
  colors=$(identify -format '%k' "$file")
  test "$colors" -gt 8
}
assert_rendered_capture "$artifact_dir/online.png"

# The Drift catalog and durable thumbnails must survive a process restart when
# both emulator transports are disabled.
$adb_bin shell svc wifi disable
$adb_bin shell svc data disable
mark_phase offline_restart
$adb_bin shell am force-stop "$package_name"
$adb_bin shell monkey -p "$package_name" 1 >"$artifact_dir/offline-launch.log"
sleep 12
dump_ui
$adb_bin shell dumpsys activity activities | grep -q "$package_name"
for _ in $(seq 1 30); do
  grep -Eq '2020|2024' /tmp/noodle-window.xml && break
  sleep 2
  dump_ui
done
grep -Eq '2020|2024' /tmp/noodle-window.xml
$adb_bin shell screencap -p /sdcard/foto-offline.png
$adb_bin pull /sdcard/foto-offline.png "$artifact_dir/offline.png" >/dev/null
! grep -Eqi 'Could not load value|Enable backup|Something went wrong' /tmp/noodle-window.xml
assert_rendered_capture "$artifact_dir/offline.png"
mark_phase complete
$adb_bin shell svc wifi enable || true
$adb_bin shell svc data enable || true
echo "FOTO offline emulator smoke passed: login, synced timeline, force-stop, offline relaunch, and local catalog render."
trap - ERR

