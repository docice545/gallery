import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

MODULE = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'foto-manifest.py'))
advance, finish = MODULE['advance'], MODULE['finish']
atomic_json, Stop = MODULE['atomic_json'], MODULE['Stop']


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.canonical, self.mirror = self.root / 'canonical.json', self.root / 'mirror.json'
        self.head = '1' * 40
        self.before = {'expected_head': '0' * 40, 'history': [{'existing': 'preserve'}], 'custom': [1, 2]}
        atomic_json(self.canonical, self.before)
        atomic_json(self.mirror, self.before)

    def update(self):
        advance(self.canonical, self.mirror, self.head, 'fixture', self.root)

    def test_preserves_history_and_unknown_fields(self):
        self.update()
        after = json.loads(self.canonical.read_text())
        self.assertEqual(after, json.loads(self.mirror.read_text()))
        self.assertEqual(after['history'][:-1], self.before['history'])
        self.assertEqual(after['custom'], self.before['custom'])
        self.assertEqual(after['expected_head'], self.head)

    def test_divergent_mirror_never_overwrites_existing_history(self):
        original = self.canonical.read_bytes()
        atomic_json(self.mirror, {'history': ['other']})
        with self.assertRaises(Stop):
            self.update()
        self.assertEqual(self.canonical.read_bytes(), original)

    def test_interruption_between_canonical_and_mirror_is_recoverable(self):
        original = atomic_json

        def interrupted(path, value):
            if path == self.mirror:
                raise OSError('injected interruption')
            return original(path, value)

        with patch.dict(finish.__globals__, atomic_json=interrupted):
            with self.assertRaises(OSError):
                self.update()
        self.assertNotEqual(self.canonical.read_bytes(), self.mirror.read_bytes())
        transaction = next(self.root.glob('manifest-transaction-*.json'))
        finish(transaction)
        finish(transaction)  # idempotent; never append history twice
        after = json.loads(self.canonical.read_text())
        self.assertEqual(after, json.loads(self.mirror.read_text()))
        self.assertEqual(len(after['history']), 2)

    def test_recovery_rejects_later_independent_changes(self):
        self.update()
        atomic_json(self.mirror, {'history': ['new independent change']})
        original = self.mirror.read_bytes()
        with self.assertRaises(Stop):
            finish(next(self.root.glob('manifest-transaction-*.json')))
        self.assertEqual(self.mirror.read_bytes(), original)

    def test_corrupt_transaction_cannot_update_manifest(self):
        self.update()
        transaction = next(self.root.glob('manifest-transaction-*.json'))
        value = json.loads(transaction.read_text())
        value['after']['expected_head'] = 'f' * 40
        atomic_json(transaction, value)
        with self.assertRaises(Stop):
            finish(transaction)

    def test_incomplete_or_invalid_manifest_is_not_replaced(self):
        self.canonical.write_text('{incomplete')
        with self.assertRaises(ValueError):
            self.update()
        self.assertEqual(self.canonical.read_text(), '{incomplete')


if __name__ == '__main__':
    unittest.main()
