import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from contextlib import redirect_stderr
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts/release' / file)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


p = module('predeploy_adapter_tests', 'trash_predeploy.py')


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.tool = module('pinned_adapter_fixture', 'trash_release.py')
        self.config = self.tool.IMAGE
        self.loaded = 'sha256:' + 'a' * 64
        self.proof = {'loadedImageId': self.loaded, 'configDigest': self.config,
                      'identityKind': 'MANIFEST_DIGEST', 'archiveSHA256': self.tool.ARCHIVE_SHA,
                      'sourceCommit': self.tool.SOURCE}

    def test_valid_proof_maps_runtime_id_and_retains_frozen_manifest_check(self):
        original = Mock(return_value=Path('archive'))
        self.tool.verify_artifact = original
        p.install_image_adapter(self.tool)
        with patch.object(p.subprocess, 'run', return_value=SimpleNamespace(returncode=0)), \
             patch.object(self.tool.image_identity, 'verify_loaded', return_value=self.proof):
            self.tool.load_artifact(Path('backend'))
        self.assertEqual(self.tool.IMAGE, self.loaded)
        self.tool.verify_artifact(Path('backend'))
        self.assertEqual(original.call_count, 2)
        self.assertEqual(self.tool.IMAGE, self.loaded)

    def test_existing_invalid_image_never_loaded_overwritten_or_journaled(self):
        self.tool.verify_artifact = Mock(return_value=Path('archive'))
        self.tool.docker = Mock()
        p.install_image_adapter(self.tool)
        with patch.object(p.subprocess, 'run', return_value=SimpleNamespace(returncode=0)), \
             patch.object(self.tool.image_identity, 'verify_loaded', side_effect=self.tool.image_identity.IdentityError('IMAGE_CONFIG_DIGEST_MISMATCH')):
            with self.assertRaisesRegex(self.tool.image_identity.IdentityError, 'DIGEST_MISMATCH'):
                self.tool.load_artifact(Path('backend'))
        self.tool.docker.assert_not_called()
        self.assertEqual(self.tool.IMAGE, self.config)
        self.assertFalse(hasattr(self.tool, 'loaded_image_proof'))

    def test_immutable_candidate_override_prevents_tag_race(self):
        with tempfile.TemporaryDirectory() as directory:
            p.install_image_adapter(self.tool); self.tool.IMAGE = self.loaded
            path = self.tool.override(Path(directory), self.tool.TAG)
            self.assertEqual(json.loads(path.read_text())['services'][self.tool.SERVICE]['image'], self.loaded)
            previous = self.tool.override(Path(directory), 'old:tag', name='rollback.json')
            self.assertEqual(json.loads(previous.read_text())['services'][self.tool.SERVICE]['image'], 'old:tag')

    def test_journal_requires_verified_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            p.install_image_adapter(self.tool)
            with self.assertRaisesRegex(p.Stop, 'PROOF_REQUIRED'):
                self.tool.save(Path(directory) / 'deployment.json', {})
            self.assertFalse((Path(directory) / 'deployment.json').exists())

    def test_private_journal_reused_by_guarded_rollback_without_original_config_id_assumption(self):
        with tempfile.TemporaryDirectory() as directory:
            p.install_image_adapter(self.tool)
            self.tool.IMAGE = self.loaded; self.tool.loaded_image_proof = self.proof
            path = Path(directory) / 'deployment.json'
            self.tool.save(path, {'source': self.tool.SOURCE})
            self.tool.IMAGE = self.config
            p.journal_image(self.tool, Path(directory))
            self.assertEqual(self.tool.IMAGE, self.loaded)
            self.assertEqual(json.loads(path.read_text())['phase'], 'PREPARED_BEFORE_QUEUE_PAUSE')

    def test_foreign_proof_cannot_authorize_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            p.install_image_adapter(self.tool)
            self.tool.save(Path(directory) / 'receipt.json', {})
            p.save(Path(directory) / 'deployment.json', {'source': self.tool.SOURCE, 'candidateImage': self.loaded,
                    'candidateImageProof': {**self.proof, 'archiveSHA256': 'wrong'}})
            with self.assertRaisesRegex(p.Stop, 'PROOF_MISSING_OR_CHANGED'):
                p.journal_image(self.tool, Path(directory))

    def test_all_mutations_refused_before_production_access_without_approval(self):
        for action in ('deploy', 'rollback', 'acceptance', 'enable-workers'):
            with patch.object(p.pwd, 'getpwuid', return_value=SimpleNamespace(pw_name='doctoriceadm')), \
                 patch.object(p, 'load_tool') as load, redirect_stderr(io.StringIO()):
                self.assertEqual(p.main([action]), 1)
                load.assert_not_called()


if __name__ == '__main__': unittest.main()
