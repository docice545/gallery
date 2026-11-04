"""Exercise actual CI commands with fake build/services, no signing or network."""

import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('release_resources', ROOT / 'scripts/release/android_release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def step_body(workflow, name):
    source = (ROOT / '.github/workflows' / workflow).read_text()
    step = re.search(r'      - name: ' + re.escape(name) + r'\n(.*?)(?=      - |\Z)', source, re.S).group(1)
    body = step.split('        run: |\n', 1)[1]
    return '\n'.join(line[10:] for line in body.splitlines())


def fake(path, source):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)
    path.chmod(0o700)


class BuildDiagnosticsTests(unittest.TestCase):
    def test_unsigned_and_hp_resource_profile_preserves_abis_flags_and_failure(self):
        command = step_body('build-mobile.yml', 'Build unsigned universal APK')
        for status in (0, 31):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fake(root / 'bin/flutter', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path('invocation.json').write_text(json.dumps({'args': sys.argv[1:], 'opts': os.environ['GRADLE_OPTS']}))
print('FINAL_JETIFIER_DIAGNOSTIC')
sys.exit(int(os.environ['FIXTURE_EXIT']))
''')
                fake(root / 'bin/git', '''#!/usr/bin/env python3
from pathlib import Path
import sys
assert sys.argv[1:] == ['diff', '--exit-code', '--', 'pubspec.lock']
Path('lock-checked').touch()
''')
                initial_opts = '-Dexisting.proxy=preserved -Dorg.gradle.parallel=true'
                env = {**os.environ, 'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH'],
                       'RUNNER_TEMP': str(root), 'VERSION_NAME': '5.7.3', 'VERSION_CODE': '37',
                       'GRADLE_OPTS': initial_opts, 'FIXTURE_EXIT': str(status)}
                result = subprocess.run(['bash', '-eo', 'pipefail', '-c', command], cwd=root,
                                        env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, status, result.stderr)
                invocation = json.loads((root / 'invocation.json').read_text())
                self.assertIn('android-arm,android-arm64,android-x64', invocation['args'])
                self.assertIn('--release', invocation['args'])
                self.assertIn('--pub', invocation['args'])
                self.assertIn('--build-number=37', invocation['args'])
                hp_env = release.android_build_environment(env)
                self.assertEqual(invocation['opts'], hp_env['GRADLE_OPTS'])
                properties = dict(item[2:].split('=', 1) for item in shlex.split(invocation['opts']))
                self.assertEqual(properties['existing.proxy'], 'preserved')
                self.assertEqual(properties['org.gradle.jvmargs'], '-Xmx6g')
                self.assertEqual(properties['org.gradle.workers.max'], '2')
                self.assertEqual(properties['org.gradle.parallel'], 'false')
                self.assertEqual(env['GRADLE_OPTS'], initial_opts)
                self.assertEqual(hp_env['PATH'], env['PATH'])
                self.assertEqual((root / 'lock-checked').exists(), status == 0)
                self.assertIn('FINAL_JETIFIER_DIAGNOSTIC', (root / 'unsigned-apk-build.log').read_text())

    def test_unsigned_cleanup_is_hosted_only_and_preserves_android_java_checkout(self):
        command = step_body('build-mobile.yml', 'Reclaim unused hosted toolchains before universal Android build')
        for actions, runner in [('true', 'github-hosted'), ('true', 'self-hosted'), ('false', 'github-hosted')]:
            with self.subTest(actions=actions, runner=runner), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fake(root / 'sudo', """#!/usr/bin/env python3
import json, sys
from pathlib import Path
with Path('mutations').open('a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
""")
                env = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                       'GITHUB_ACTIONS': actions, 'RUNNER_ENVIRONMENT': runner}
                result = subprocess.run(['bash', '-eo', 'pipefail', '-c', command], cwd=root,
                                        env=env, text=True, capture_output=True, timeout=10)
                allowed = actions == 'true' and runner == 'github-hosted'
                self.assertEqual(result.returncode == 0, allowed, result.stderr)
                mutations = root / 'mutations'
                self.assertEqual(mutations.exists(), allowed)
                if allowed:
                    self.assertEqual([json.loads(line) for line in mutations.read_text().splitlines()], [
                        ['rm', '-rf', '/usr/share/dotnet', '/opt/ghc', '/opt/hostedtoolcache/CodeQL'],
                        ['docker', 'image', 'prune', '--all', '--force'],
                    ])

    def test_api_failure_is_not_hidden_by_tee_and_evidence_is_bounded(self):
        workflow = 'original-noodle-gallery-compatibility.yml'
        command = step_body(workflow, 'Run disposable backend API smoke flows')
        diagnostics = step_body(workflow, 'Expose failed API operation and disposable backend evidence')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake(root / 'tools/original-noodle-gallery/api_smoke.sh', '''#!/usr/bin/env bash
printf 'curl: (22) HTTP 404\\nAPI smoke failed at stage downloads: test -s thumbnail.jpg\\n' >&2
exit 76
''')
            fake(root / 'bin/docker', '''#!/usr/bin/env python3
import sys
assert sys.argv[1:] == ['compose', '-f', 'e2e/docker-compose.yml', 'logs', '--no-color', '--tail=120', 'immich-server']
print('synthetic backend evidence ' * 1200)
print('FINAL_BACKEND_FAILURE\\n::error::untrusted output')
''')
            helper = root / '.github/scripts/report-ci-failures.py'
            helper.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / '.github/scripts/report-ci-failures.py', helper)
            env = {**os.environ, 'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH'], 'RUNNER_TEMP': str(root)}
            result = subprocess.run(['bash', '-eo', 'pipefail', '-c', command], cwd=root,
                                    env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 76, result.stderr)
            evidence = subprocess.run(['bash', '-eo', 'pipefail', '-c', diagnostics], cwd=root,
                                      env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(evidence.returncode, 0, evidence.stderr)
            annotations = evidence.stdout.splitlines()
            self.assertLessEqual(len(annotations), 6)
            self.assertTrue(all(line.startswith('::error title=') and len(line) < 4096 for line in annotations))
            self.assertIn('HTTP 404', evidence.stdout)
            self.assertIn('stage downloads: test -s thumbnail.jpg', evidence.stdout)
            self.assertIn('FINAL_BACKEND_FAILURE', evidence.stdout)
            self.assertIn('%0A::error::untrusted output', evidence.stdout)


if __name__ == '__main__':
    unittest.main()
