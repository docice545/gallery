#!/usr/bin/env python3
"""Read-only Android checks. Never builds, signs, installs, fetches or deploys."""
import argparse
import hashlib
import getpass
import warnings
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

HP_SHA = '54f335e2a28af2de6d485f5a53acb05934837324'
HOTFIX = 'fc1126dd4a283d7ab803c237d45914b3d60b5568'
PACKAGE = 'de.opennoodle.gallery'
HISTORICAL_CERT = 'ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(args, cwd=None):
    result = subprocess.run([str(x) for x in args], cwd=cwd, capture_output=True, text=True)
    require(result.returncode == 0, f'{Path(str(args[0])).name} read-only check failed (exit {result.returncode}); inspect locally')
    return result.stdout


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def sdk_tools(repo, explicit=None):
    roots = []
    if explicit:
        roots = [Path(explicit)]
    else:
        for name in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
            if os.environ.get(name):
                roots.append(Path(os.environ[name]))
        props = repo / 'mobile/android/local.properties'
        if props.is_file():
            for line in props.read_text(errors='replace').splitlines():
                match = re.fullmatch(r'\s*sdk\.dir\s*=\s*(.+?)\s*', line)
                if match:
                    roots.append(Path(match[1].replace('\\:', ':').replace('\\ ', ' ').replace('\\\\', '\\')))
        roots += [Path.home() / 'Android/Sdk', Path('/opt/android-sdk'), Path('/opt/android-sdk-linux'), Path('/usr/lib/android-sdk')]
    checked = set()
    for root in roots:
        root = root.expanduser().resolve()
        if root in checked:
            continue
        checked.add(root)
        folder = root / 'build-tools'
        if not folder.is_dir():
            continue
        versions = [p for p in folder.iterdir() if p.is_dir() and re.fullmatch(r'\d+\.\d+\.\d+', p.name)]
        versions.sort(key=lambda p: (p.name == '36.0.0', tuple(map(int, p.name.split('.')))), reverse=True)
        for tools in versions:
            if all(os.access(tools / n, os.X_OK) for n in ('aapt', 'apksigner')):
                return {'sdk': str(root), 'build_tools': tools.name,
                        'aapt': str(tools / 'aapt'), 'apksigner': str(tools / 'apksigner'),
                        'adb': str(root / 'platform-tools/adb'),
                        'release_helper_sdk_36_present': (root / 'platforms/android-36/android.jar').is_file(),
                        'release_helper_tools_36_0_0_present': all(os.access(folder / '36.0.0' / n, os.X_OK) for n in ('aapt', 'apksigner'))}
    raise ValueError('Build-tools pair not found in configured/common SDK locations. Supply --sdk EXISTING_SDK; no tools were installed.')


def apk_metadata(apk, tools):
    require(apk.is_file() and apk.stat().st_size > 0, 'APK is missing/empty')
    badging = run([tools['aapt'], 'dump', 'badging', apk])
    package_line = next((line for line in badging.splitlines() if line.startswith('package:')), '')
    fields = dict(re.findall(r"(\w+)='([^']*)'", package_line))
    require(fields.get('name') == PACKAGE, 'APK packageName differs from de.opennoodle.gallery; stop')
    require(fields.get('versionCode', '').isdigit(), 'APK versionCode is missing')
    signed = run([tools['apksigner'], 'verify', '--verbose', '--print-certs', apk])
    certificates = re.findall(r'Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F:]+)', signed)
    require(len(certificates) == 1, 'Expected exactly one APK signer; investigate multiple/missing signers')
    certificate = certificates[0].replace(':', '').lower()
    require(re.fullmatch('[0-9a-f]{64}', certificate), 'Invalid certificate fingerprint')
    return {'packageName': fields['name'], 'versionCode': int(fields['versionCode']),
            'versionName': fields.get('versionName'), 'certificateSHA256': certificate,
            'apkSHA256': sha(apk), 'bytes': apk.stat().st_size,
            'matches_historical_certificate': certificate == HISTORICAL_CERT}


def keys_match(repo, baseline):
    key = repo / 'mobile/android/key.jks'
    props = repo / 'mobile/android/key.properties'
    require(key.is_file() and props.is_file(), 'Confirmed HP signing files not found at this invocation path; do not generate replacements')
    require(not run(['git', 'ls-files', '--', 'mobile/android/key.jks', 'mobile/android/key.properties'], repo).strip(), 'Signing files are tracked: stop')
    ignored = set(run(['git', 'check-ignore', '--', 'mobile/android/key.jks', 'mobile/android/key.properties'], repo).splitlines())
    require(len(ignored) == 2, 'Both signing files must remain ignored')
    # Read ONLY the alias into a variable. Never output the properties contents,
    # password values or an arbitrary parse error containing them.
    aliases = re.findall(r'(?m)^[ \t\f]*keyAlias[ \t\f]*[:=][ \t\f]*([A-Za-z0-9_.-]+)[ \t\f]*\r?$', props.read_text(encoding='latin1'))
    require(len(aliases) == 1, 'keyAlias syntax needs local review; properties contents intentionally hidden')
    keytool = shutil.which('keytool')
    if not keytool and os.environ.get('JAVA_HOME'):
        candidate = Path(os.environ['JAVA_HOME']) / 'bin/keytool'
        if candidate.is_file():
            keytool = str(candidate)
    require(keytool, 'Use keytool from the existing JDK; nothing installed')
    before = [sha(key), sha(props)]
    require(sys.stdin.isatty(), 'Run keys in a private interactive HP terminal; no password accepted via argv or logs')
    with warnings.catch_warnings():
        warnings.simplefilter('error', getpass.GetPassWarning)
        password = getpass.getpass('Existing keystore password (local, hidden): ')
    require(password, 'An empty password cannot verify keystore integrity')
    try:
        # Password enters only the child stdin pipe; never argv/env/log output.
        result = subprocess.run([keytool, '-J-Duser.language=en', '-J-Duser.country=US',
                                 '-list', '-v', '-keystore', str(key), '-alias', aliases[0]],
                                input=password+'\n', stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
    finally:
        del password
    require([sha(key), sha(props)] == before, 'Signing files changed during check; stop')
    require(result.returncode == 0, 'keytool could not verify the existing entry; nothing signed')
    require('Entry type: PrivateKeyEntry' in result.stdout, 'Configured alias is not a PrivateKeyEntry')
    certs = re.findall(r'(?m)^\s*SHA256:\s*([A-Fa-f0-9:]+)\s*$', result.stdout)
    require(certs, 'Cannot read certificate SHA-256 from keytool')
    cert = certs[0].replace(':', '').lower()
    require(cert == baseline['certificateSHA256'], 'Build39 APK / configured keystore certificate MISMATCH; no new key and no uninstall')
    return {'files_unchanged': True, 'configured_entry_is_private_key': True,
            'certificateSHA256': cert, 'matches_build39_apk': True,
            'matches_historical_certificate': cert == HISTORICAL_CERT,
            'actual_signing_performed': False}


def history(repo):
    head = run(['git', 'rev-parse', 'HEAD'], repo).strip()
    branch = run(['git', 'branch', '--show-current'], repo).strip()
    require(head == HP_SHA and branch == 'foto-build39-hp-serial-tests', 'HP HEAD/branch changed since supplied receipt; preserve it and review')
    result = {'hp_head': head, 'hp_branch': branch,
              'status': run(['git', 'status', '--short'], repo).splitlines(),
              'commit_and_parents': run(['git', 'show', '-s', '--format=%H%n%P%n%s', HP_SHA], repo).splitlines(),
              'commit_changed_paths': run(['git', 'diff-tree', '--root', '--no-commit-id', '--name-status', '-r', HP_SHA], repo).splitlines()}
    reflog = subprocess.run(['git', 'reflog', 'show', '--format=%H %gs', '-n', '12', branch], cwd=repo, capture_output=True, text=True)
    result['local_reflog'] = reflog.stdout.splitlines() if reflog.returncode == 0 else []
    target = subprocess.run(['git', 'cat-file', '-e', HOTFIX+'^{commit}'], cwd=repo, capture_output=True)
    if target.returncode:
        result['hotfix_object'] = 'FETCH_REQUIRED: git fetch --no-tags origin refs/heads/codex/foto-build38-unified-16'
        return result
    result['hotfix_commit_and_parents'] = run(['git', 'show', '-s', '--format=%H%n%P%n%s', HOTFIX], repo).splitlines()
    base = subprocess.run(['git', 'merge-base', HP_SHA, HOTFIX], cwd=repo, capture_output=True, text=True)
    require(base.returncode == 0, 'No common ancestor confirmed; preserve both histories and investigate')
    result['common_ancestor'] = base.stdout.strip()
    result['hp_only_commits'] = run(['git', 'log', '--oneline', HOTFIX+'..'+HP_SHA], repo).splitlines()
    result['hp_only_changed_paths'] = run(['git', 'diff', '--name-status', base.stdout.strip(), HP_SHA], repo).splitlines()
    result['hp_only_mobile_paths'] = run(['git', 'diff', '--name-status', base.stdout.strip(), HP_SHA, '--', 'mobile', 'scripts/release'], repo).splitlines()
    result['mobile_delta_to_hotfix'] = run(['git', 'diff', '--name-status', HP_SHA, HOTFIX, '--', 'mobile', 'scripts/release'], repo).splitlines()
    result['patch_equivalence'] = run(['git', 'log', '--left-right', '--cherry-mark', '--oneline', HP_SHA+'...'+HOTFIX, '--', 'mobile', 'scripts/release'], repo).splitlines()
    return result


def next_version_code(baseline_code, installed_code):
    # Android update counter only; never infer it from the product build name.
    require(all(isinstance(code, int) and 0 < code <= 2100000000
                for code in (baseline_code, installed_code)), 'Invalid measured Android versionCode')
    candidate = max(baseline_code, installed_code) + 1
    require(candidate <= 2100000000, 'Android versionCode limit reached')
    return candidate


def device(repo, serial, baseline, tools):
    require(serial, 'Pass --serial for the selected Samsung')
    adb = tools['adb']
    require(os.access(adb, os.X_OK), 'adb missing in the selected existing SDK')
    require(run([adb, '-s', serial, 'get-state']).strip() == 'device', 'Samsung is not authorized/connected')
    dump = run([adb, '-s', serial, 'shell', 'dumpsys', 'package', PACKAGE])
    code = re.search(r'\bversionCode=(\d+)', dump)
    require(code, 'Installed FOTO versionCode not found')
    paths = run([adb, '-s', serial, 'shell', 'pm', 'path', PACKAGE]).splitlines()
    base = [p.strip()[8:] for p in paths if p.startswith('package:') and p.strip().endswith('/base.apk')]
    require(len(base) == 1, 'Expected exactly one installed base.apk')
    # Only a temporary copy of the installed APK; no photo data or keys copied.
    with tempfile.TemporaryDirectory(prefix='foto-preflight-', dir=repo.parent) as temporary:
        installed_apk = Path(temporary) / 'installed-base.apk'
        run([adb, '-s', serial, 'pull', base[0], installed_apk])
        installed = apk_metadata(installed_apk, tools)
    require(installed['versionCode'] == int(code[1]), 'Device changed during snapshot; repeat read-only check')
    require(installed['certificateSHA256'] == baseline['certificateSHA256'], 'Installed app / Build39 APK certificate MISMATCH; do not uninstall')
    next_code = next_version_code(baseline['versionCode'], installed['versionCode'])
    return {'installed': installed, 'installed_matches_build39_file': installed['apkSHA256'] == baseline['apkSHA256'],
            'next_version_code': next_code, 'install_performed': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['history', 'sdk', 'apk', 'keys', 'device'])
    parser.add_argument('--repo', type=Path, default=Path('/mnt/hp-data/foto-build38/source'))
    parser.add_argument('--apk', type=Path, default=Path('/home/doctoriceadm/FOTO-Build39.apk'))
    parser.add_argument('--sdk')
    parser.add_argument('--serial')
    args = parser.parse_args()
    try:
        if args.mode == 'history':
            result = history(args.repo)
        else:
            tools = sdk_tools(args.repo, args.sdk)
            if args.mode == 'sdk':
                result = tools
            else:
                baseline = apk_metadata(args.apk, tools)
                result = baseline if args.mode == 'apk' else keys_match(args.repo, baseline) if args.mode == 'keys' else device(args.repo, args.serial, baseline, tools)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0
    except ValueError as error:
        print('BLOCKED: '+str(error), file=sys.stderr)
        return 1
    except (OSError, EOFError, getpass.GetPassWarning, subprocess.SubprocessError):
        print('BLOCKED: local file/tool access failed; inspect HP paths/permissions without printing credentials', file=sys.stderr)
        return 1

if __name__ == '__main__':
    sys.exit(main())
