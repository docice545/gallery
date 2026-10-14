"""Execute the actual bounded APT selector embedded in the CI workflow."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

WORKFLOW = Path(__file__).resolve().parents[3] / '.github/workflows/gallery-trash-release-proof.yml'
EXPECTED = '5:28.4.0-1~ubuntu.24.04~noble'
SOURCE = 'https://download.docker.com/linux/ubuntu'


class SignedDockerSelection(unittest.TestCase):
    def execute(self, rows):
        section = WORKFLOW.read_text().split('for package in docker-ce docker-ce-cli; do', 1)[1]
        program = section.split("<<'PY'\n", 1)[1].split('\n          PY', 1)[0]
        program = '\n'.join(line[10:] for line in program.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'public-package-versions'
            path.write_text(rows)
            result = subprocess.run([sys.executable, '-', 'docker-ce', EXPECTED, str(path)],
                                    input=program, text=True, capture_output=True)
        notices = [line.split('::', 2)[2] for line in result.stdout.splitlines() if line.startswith('::notice')]
        return result, json.loads(notices[0]) if notices else None

    def row(self, version=EXPECTED, source=SOURCE, package='docker-ce'):
        return f'  {package} | {version} | {source} noble/stable amd64 Packages\n'

    def test_exact_signed_repository_package_is_selected(self):
        result, notice = self.execute(self.row())
        self.assertEqual(result.returncode, 0)
        self.assertTrue(notice['expectedVersionPresent'])
        self.assertEqual(notice['availableOfficialVersions'], [EXPECTED])

    def test_canonical_trailing_slash_does_not_change_repository_identity(self):
        result, notice = self.execute(self.row(source=SOURCE + '/'))
        self.assertEqual(result.returncode, 0)
        self.assertTrue(notice['officialRepositoryPresent'])

    def test_other_repository_or_package_cannot_authorize_the_same_version(self):
        for row in (self.row(source='https://other.invalid/ubuntu'), self.row(package='other-package'),
                    self.row(source='https://PRIVATE_TOKEN@download.docker.com/linux/ubuntu')):
            with self.subTest(row=row):
                result, notice = self.execute(row)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(notice['expectedVersionPresent'])
                self.assertNotIn('PRIVATE_TOKEN', result.stdout + result.stderr)

    def test_missing_version_or_repository_is_an_explicit_stop(self):
        for rows in ('', self.row(version='5:28.3.0-1~ubuntu.24.04~noble')):
            with self.subTest(rows=rows):
                result, notice = self.execute(rows)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(notice['expectedVersionPresent'])
                self.assertIn('PINNED_OFFICIAL_DOCKER_PACKAGE_UNAVAILABLE', result.stdout)

    def test_notice_is_bounded_without_truncating_actual_version_search(self):
        rows = ''.join(self.row(version=f'5:30.0.{i}-1~ubuntu.24.04~noble') for i in range(20)) + self.row()
        result, notice = self.execute(rows)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(notice['availableOfficialVersions']), 8)


if __name__ == '__main__':
    unittest.main()
