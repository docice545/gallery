import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import build11_artifacts as m
import gallery_entry as entry


def profile():
    source = 'a' * 40
    mobile = dict(sourceCommit=source, run=1, artifactId=2, sha256='b' * 64)
    return dict(schemaVersion=3, productionBase=m.BASE, sourceCommit=source,
                serverVersion='5.7.3', mobileVersion='5.7.3', mobileBuild=11,
                backend=dict(sourceCommit=source, serverVersion='5.7.3', mobileVersion='5.7.3', mobileBuild=11,
                             platform='linux/amd64', deployment='NOT_DEPLOYED', imageId='sha256:'+'c'*64,
                             archiveSHA256='d'*64, imageTag='gallery-server:trash-'+source[:12]),
                backendRun=1, backendArtifactId=2, android={**mobile, 'certificateSHA256': 'e'*64}, ios=mobile.copy())


class Profiles(unittest.TestCase):
    def test_build11_only_same_exact_application_revision(self):
        value = profile(); self.assertEqual(m.validate(value), value)
        for field in ('sourceCommit', 'mobileVersion', 'mobileBuild', 'backend'):
            broken = copy.deepcopy(value)
            if field == 'backend': broken[field]['sourceCommit'] = 'b'*40
            else: broken[field] = {'sourceCommit': 'invalid', 'mobileVersion': '5.7.2', 'mobileBuild': 10}[field]
            with self.subTest(field=field), self.assertRaises(ValueError): m.validate(broken)

    def test_production_certificate_cannot_be_mislabeled_as_ci_validation_artifact(self):
        value = profile(); value['android']['certificateSHA256'] = m.android.CERTIFICATE_SHA256
        with self.assertRaisesRegex(ValueError, 'NOT_HP'): m.validate(value)

    def test_pinned_profile_reads_same_buffer_and_rejects_hash_or_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'profile.json'; path.write_text(json.dumps(profile()))
            expected = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(m.load(path, expected), profile())
            with self.assertRaises(ValueError): m.load(path, '0'*64)
            alias = Path(directory) / 'link'; alias.symlink_to(path)
            with self.assertRaises(OSError): m.load(alias, expected)
            path.write_text(json.dumps({**profile(), 'mobileBuild': 10}))
            with self.assertRaises(ValueError): m.load(path, expected)


class Package(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in entry.REQUIRED_TOOLS:
            path = self.root / 'tools' / name; path.parent.mkdir(exist_ok=True); path.write_text('fixture')
        for name in ('backend/manifest.json', 'backend/build11-rollback-runtime.json', 'backend/gallery-server-linux-amd64.tar.gz', 'android/app-release.apk',
                     'ios/Photos-unsigned.ipa', 'rollback/manifest.json', 'rollback/gallery-server-linux-amd64.tar.gz',
                     'config/docker-compose.yml', 'docs/BUILD11-RELEASE-RUNBOOK.md',
                     'docs/BUILD11-UPSTREAM-COMPATIBILITY.md', 'docs/BUILD11-USER-MANUAL-RU.md', 'docs/BUILD11-TEST-REPORT.md',
                     'ios-tools/release/prepare_sidestore.py', 'ios-tools/release/ios_artifact.py',
                     'ios-tools/package_unsigned_ios.py', 'ios-tools/verify_ios_archive.py'):
            path = self.root / name; path.parent.mkdir(exist_ok=True, parents=True); path.write_text('fixture')
        (self.root / 'candidate-profile.json').write_text(json.dumps(profile()))
        (self.root / 'reviewed-compatibility.json').write_text(json.dumps(
            {'testReportSHA256':m.digest(self.root/'backend/build11-rollback-runtime.json')}))
        config = dict(schemaVersion=1, profileSHA256=m.digest(self.root/'candidate-profile.json'),
                      compatibilitySHA256=m.digest(self.root/'reviewed-compatibility.json'),
                      sourceCommit='a'*40, version='5.7.3', build=11)
        (self.root/'release-operator.json').write_text(json.dumps(config))
        self.update()

    def update(self):
        files = sorted(p for p in self.root.rglob('*') if p.is_file() and p.name != 'SHA256SUMS')
        (self.root/'SHA256SUMS').write_text(''.join(m.digest(p)+'  '+p.relative_to(self.root).as_posix()+'\n' for p in files))

    def test_complete_package_is_verified(self):
        self.assertEqual(entry.verify_package(self.root)['schemaVersion'], 1)

    def test_tampered_or_missing_tool_fails(self):
        (self.root/'tools/image_release.py').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'FILE_CHANGED'): entry.verify_package(self.root)

    def test_unlisted_executable_cannot_escape_checksums(self):
        (self.root/'tools/unlisted.py').write_text('fixture')
        with self.assertRaisesRegex(ValueError, 'MUST_BE_CHECKSUMMED'): entry.verify_package(self.root)

    def test_operator_source_version_and_missing_payload_are_rejected(self):
        for field, value in (('sourceCommit', 'b'*40), ('version', '5.7.2'), ('build', 10)):
            config = json.loads((self.root/'release-operator.json').read_text())
            previous = config[field]; config[field] = value
            (self.root/'release-operator.json').write_text(json.dumps(config)); self.update()
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'SOURCE_VERSION_MISMATCH'):
                entry.verify_package(self.root)
            config[field] = previous; (self.root/'release-operator.json').write_text(json.dumps(config))
        (self.root/'ios/Photos-unsigned.ipa').unlink(); self.update()
        with self.assertRaisesRegex(ValueError, 'MUST_BE_CHECKSUMMED'): entry.verify_package(self.root)

    def test_symlink_directory_is_rejected_even_if_it_contains_no_listed_file(self):
        with tempfile.TemporaryDirectory() as outside:
            (self.root/'unlisted-dir').symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'MUST_BE_CHECKSUMMED'): entry.verify_package(self.root)

    def test_path_escape_duplicate_and_symlink_are_rejected(self):
        for extra in ('a'*64+'  ../outside\n', 'a'*64+'  /etc/passwd\n', 'a'*64+'  tools/image_release.py\n'):
            self.update()
            with (self.root/'SHA256SUMS').open('a') as file: file.write(extra)
            with self.subTest(extra=extra), self.assertRaises(ValueError): entry.verify_package(self.root)
        self.update(); target=self.root/'tools/image_release.py'; target.unlink(); target.symlink_to(self.root/'candidate-profile.json')
        with self.assertRaisesRegex(ValueError, 'SYMLINK'): entry.verify_package(self.root)


if __name__ == '__main__': unittest.main()
