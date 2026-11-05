"""Run the real CI formatter command with a cwd-sensitive fake SDK shim."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


class ReleaseFormatterContextTests(unittest.TestCase):
    def test_mobile_mise_context_and_format_failure_are_preserved(self):
        source = (ROOT / '.github/workflows/static_analysis.yml').read_text()
        step = re.search(r'      - name: Run complete release Dart format gate\n(.*?)(?=      - name:)', source, re.S).group(1)
        self.assertIn('working-directory: mobile', step)
        body = step.split('        run: |\n', 1)[1]
        body = '\n'.join(line[10:] for line in body.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / 'scripts/release/android_release.py'
            helper.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / 'scripts/release/android_release.py', helper)
            paths = ['mobile/lib/source.dart', 'mobile/test/source_test.dart',
                     'mobile/integration_test/source_test.dart', 'mobile/lib/generated.g.dart']
            for relative in paths:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('// synthetic source\n')
            subprocess.run(['git', 'init', '--quiet', str(root)], check=True)
            subprocess.run(['git', 'add', '--', *paths], cwd=root, check=True)
            tools = root / 'fake-tools'
            tools.mkdir()
            shim = tools / 'dart'
            shim.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
assert Path.cwd().name == 'mobile', 'mise resolves the mobile SDK from the command cwd'
Path(os.environ['RUNNER_TEMP'], 'invocation.json').write_text(json.dumps({'cwd': str(Path.cwd()), 'args': sys.argv[1:]}))
print('synthetic formatter changed source')
sys.exit(23)
""")
            shim.chmod(0o700)
            result = subprocess.run(
                ['bash', '--noprofile', '--norc', '-eo', 'pipefail', '-c', body],
                cwd=root / 'mobile', env={**os.environ, 'RUNNER_TEMP': str(root),
                                         'PATH': str(tools) + os.pathsep + os.environ['PATH']},
                text=True, capture_output=True, timeout=10,
            )
            self.assertEqual(result.returncode, 23, result.stderr)
            invocation = json.loads((root / 'invocation.json').read_text())
            self.assertEqual(invocation['cwd'], str(root / 'mobile'))
            self.assertEqual(invocation['args'][:2], ['format', '--set-exit-if-changed'])
            self.assertEqual(set(invocation['args'][2:]), {str(root / item) for item in paths[:3]})
            self.assertIn('synthetic formatter changed source', (root / 'release-format.log').read_text())


if __name__ == '__main__':
    unittest.main()
