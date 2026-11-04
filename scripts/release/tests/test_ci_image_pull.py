"""Only transient registry pulls retry; no actual Docker daemon or network."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parents[3] / '.github/scripts/pull-ci-images.sh'


class RegistryPullTests(unittest.TestCase):
    def run_pull(self, message, failures, hosted=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            docker = root / 'docker'
            docker.write_text('''#!/bin/sh
n=$(cat "$PULL_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s' "$n" > "$PULL_COUNT"
[ "$*" = 'compose pull --ignore-buildable' ] || exit 99
if [ "$n" -le "$PULL_FAILURES" ]; then
  printf '%s\\n' "$PULL_MESSAGE"
  exit 17
fi
''')
            docker.chmod(0o700)
            sleeper = root / 'sleep'
            sleeper.write_text('#!/bin/sh\nprintf \'%s\\n\' \"$1\" >> \"$PULL_SLEEPS\"\n')
            sleeper.chmod(0o700)
            result = subprocess.run(['bash', str(HELPER)], cwd=root, capture_output=True, text=True, env={
                **os.environ, 'PATH': f'{root}:{os.environ["PATH"]}', 'GITHUB_ACTIONS': 'true',
                'RUNNER_ENVIRONMENT': 'github-hosted' if hosted else 'self-hosted',
                'PULL_SLEEPS': str(root / 'sleeps'), 'PULL_COUNT': str(root / 'count'), 'PULL_MESSAGE': message, 'PULL_FAILURES': str(failures),
            })
            count = int((root / 'count').read_text()) if (root / 'count').exists() else 0
            sleeps = (root / 'sleeps').read_text().splitlines() if (root / 'sleeps').exists() else []
            self.assertEqual(sleeps, ['30', '60'][:max(0, count - 1)])
            return result, count

    def test_rate_limit_retries_pull_only_and_preserves_failure_output(self):
        result, count = self.run_pull('toomanyrequests: retry-after: 721us', 2)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(count, 3)
        self.assertEqual(result.stdout.count('toomanyrequests'), 2)

    def test_registry_failure_stays_failed_after_three_attempts(self):
        result, count = self.run_pull('toomanyrequests', 10)
        self.assertEqual(result.returncode, 17)
        self.assertEqual(count, 3)

    def test_auth_or_build_errors_do_not_retry(self):
        for message in ['unauthorized', 'Dockerfile syntax error', 'manifest unknown']:
            result, count = self.run_pull(message, 10)
            self.assertEqual(result.returncode, 17)
            self.assertEqual(count, 1)

    def test_self_hosted_or_production_runner_is_rejected(self):
        result, count = self.run_pull('toomanyrequests', 10, hosted=False)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(count, 0)
