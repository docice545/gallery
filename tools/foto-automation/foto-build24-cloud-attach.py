#!/usr/bin/env python3
"""Launch the installed synthetic test APK, without installing or clearing data."""
import re
import subprocess
import time
import urllib.parse

PACKAGE = 'de.opennoodle.gallery.debug'


def adb(*args):
    return subprocess.run(['adb', *args], capture_output=True, text=True,
                          check=True, timeout=20).stdout.strip()


assert adb('shell', 'getprop', 'ro.kernel.qemu') == '1'
result = adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.MAIN',
             '-c', 'android.intent.category.LAUNCHER',
             '--ez', 'start-paused', 'true',
             '--ez', 'enable-checked-mode', 'true',
             '--ez', 'verify-entry-points', 'true',
             '-n', f'{PACKAGE}/app.alextran.immich.MainActivity')
assert 'Error:' not in result and 'Error type' not in result, result
deadline = time.monotonic() + 120
while time.monotonic() < deadline:
    pid = adb('shell', 'pidof', PACKAGE)
    assert re.fullmatch(r'\d+', pid), 'Expected one main FOTO process'
    logs = adb('logcat', '-d', f'--pid={pid}', '-s', 'flutter:I', '*:S')
    urls = re.findall(r'(?:Dart VM service|VM Service) is listening on (http://\S+)', logs)
    if urls:
        uri = urllib.parse.urlsplit(urls[-1])
        assert uri.hostname == '127.0.0.1' and uri.port and uri.path
        port = adb('forward', 'tcp:0', f'tcp:{uri.port}')
        assert port.isdecimal()
        print(urllib.parse.urlunsplit(uri._replace(netloc=f'127.0.0.1:{port}')))
        break
    time.sleep(0.5)
else:
    raise SystemExit('Installed FOTO did not publish its debug VM service')
