#!/usr/bin/env python3
"""Operate real Shizuku/Photo Picker on a synthetic CI emulator only."""
import json
import pathlib
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

mode, receipts = sys.argv[1:]
receipts = pathlib.Path(receipts)
package = 'de.opennoodle.gallery.debug'

def adb(*args, check=True):
    return subprocess.run(['adb', *args], capture_output=True, text=True, check=check, timeout=20).stdout.strip()

assert adb('shell', 'getprop', 'ro.kernel.qemu') == '1'
phase_file = f'app_flutter/cloud24-phase-{mode}'
started = False
picker = False
selected_tapped = False
start = time.monotonic()
while time.monotonic() - start < 1200:
    phase = adb('shell', 'run-as', package, 'cat', phase_file, check=False)
    if phase == 'healthy' and not started:
        dump = adb('shell', 'dumpsys', 'package', 'moe.shizuku.privileged.api')
        (receipts / f'cloud-{mode}-shizuku-package.txt').write_text(dump)
        apk = adb('shell', 'pm', 'path', 'moe.shizuku.privileged.api').removeprefix('package:')
        assert re.fullmatch(r'/data/app/[A-Za-z0-9_./=+~-]+', apk)
        # Android 16 dumpsys does not expose ApplicationInfo.nativeLibraryDir.
        # This harness uses only x86_64 AVDs and the pinned universal APK; ask
        # PackageManager for its installed base, then verify its actual starter.
        assert adb('shell', 'getprop', 'ro.product.cpu.abi') == 'x86_64'
        starter = str(pathlib.PurePosixPath(apk).parent / 'lib/x86_64/libshizuku.so')
        adb('shell', 'test', '-x', starter)
        print(adb('shell', starter, f'--apk={apk}'), flush=True)
        started = True
    if phase == 'picker' and not picker:
        launch = adb('shell', 'am', 'start', '-a', 'android.provider.action.PICK_IMAGES', '-t', 'image/*')
        if 'Error:' in launch:
            raise SystemExit('System Photo Picker launch failed')
        picker = True
        adb('shell', 'run-as', package, 'touch', f'app_flutter/cloud24-picker-opened-{mode}')
        print('Opened real ACTION_PICK_IMAGES activity', flush=True)
    if phase in ('healthy', 'settings', 'picker', 'verified'):
        adb('shell', 'uiautomator', 'dump', '/sdcard/cloud24-window.xml', check=False)
        xml = adb('shell', 'cat', '/sdcard/cloud24-window.xml', check=False)
        (receipts / f'cloud-{mode}-last-window.xml').write_text(xml)
        try:
            nodes = list(ET.fromstring(xml).iter('node'))
        except ET.ParseError:
            nodes = []
        for node in nodes:
            if node.get('enabled') != 'true':
                continue
            label = node.get('text', '').strip()
            owner = node.get('package', '')
            permission = owner == 'moe.shizuku.privileged.api' and label.lower() in ('allow all the time', 'allow', 'always allow')
            provider = phase == 'settings' and 'providers.media' in owner and label == 'Фото' and not selected_tapped
            confirm = phase == 'settings' and 'providers.media' in owner and label.lower() in ('allow', 'ok', 'use this app')
            if not (permission or provider or confirm):
                continue
            bounds = list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
            if len(bounds) != 4:
                continue
            x1, y1, x2, y2 = bounds
            adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
            print(json.dumps({'phase': phase, 'action': label, 'package': owner}), flush=True)
            if provider:
                selected_tapped = True
            break
    if phase in ('verified', 'done'):
        adb('shell', 'screencap', '-p', f'/sdcard/cloud24-{mode}.png')
        adb('pull', f'/sdcard/cloud24-{mode}.png', str(receipts / f'cloud-{mode}-picker.png'))
        adb('shell', 'input', 'keyevent', 'BACK')
        adb('shell', 'am', 'start', '-f', '0x00020000', '-n', f'{package}/app.alextran.immich.MainActivity')
        adb('shell', 'run-as', package, 'touch', f'app_flutter/cloud24-ui-returned-{mode}')
        print('PASS: actual system picker queried the admitted shared SQLite pool', flush=True)
        sys.exit(0)
    time.sleep(1)
raise SystemExit('Shizuku / real picker UI did not reach the verified phase')
