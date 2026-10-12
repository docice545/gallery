"""Orchestration/isolation regressions. Mock Docker; synthetic private data only."""
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('queued_delete', ROOT / 'scripts/release/hp_build10_queued_delete.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class Fixture(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='gallery-queued-release-test-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.runroot = self.root / 'gallery-build10-release-TxDlXAuj'; self.runroot.mkdir(mode=0o700)
        self.r = m.Runner(self.runroot)
        self.r.phase.mkdir(mode=0o700)
        self.state = self.runroot / 'hardened-rollback/image-state'; self.state.mkdir(mode=0o700, parents=True)
        self.snapshot = {'paused': True, 'counts': {'paused': 27}, 'mediaRoot': '/data', 'knownBackgroundJobs': ['FileDelete', 'MemoryGenerate'],
                         'jobs': [{'id': id, 'name': 'FileDelete', 'hash': id} for id in m.IDS] +
                                 [{'id': str(1000+i), 'name': 'MemoryGenerate', 'hash': str(i)} for i in range(21)],
                         'rootPhysical': [{'path': '/data/'+f, 'device': '1', 'inode': str(i), 'uid': '0', 'gid': '0'}
                                          for i, f in enumerate(('thumbs', 'encoded-video', 'profile'))]}
        self.core = self.r.core
        self.core.inspect = Mock(return_value={'Image': self.r.hp.CURRENT})
        self.core.identity = Mock()
        self.core.inventory = Mock(return_value={'/postgres': {'id': 'unchanged'}})
        self.core.prerequisites = Mock()
        self.core.execute = Mock()
        self.core.run = Mock()
        self.r.hp.binding = Mock(return_value=self.state)
        self.r.start_helper = Mock()
        self.r.close_helper = Mock()
        self.result = {'completed': True, 'records': [], 'preserved': 21, 'queuePaused': True, 'originalsDeleted': 0}
        self.actions = []
        def node(action, **kwargs):
            self.actions.append(action)
            if action == 'inventory': return self.snapshot
            if action == 'admit': return {'passed': True}
            if action == 'prepare': return {'snapshotSeal': self.r.values()['snapshotSeal'], 'proofs': []}
            if action == 'execute': return self.result
            if action == 'gate': return {'passed': True, 'preserved': 21}
            self.fail('Unexpected native action: ' + action)
        self.r.node = Mock(side_effect=node)

    def run_operator(self, execute=True):
        with patch.dict(os.environ, {'GALLERY_USER_QUEUED_DELETION_APPROVED': 'YES', 'GALLERY_DEPLOYMENT_APPROVED': 'YES'}), \
                redirect_stdout(io.StringIO()):
            self.r.run(execute)

    def test_inventory_only_never_creates_helper_deletes_or_deploys(self):
        self.run_operator(False)
        self.assertEqual(self.actions, ['inventory', 'admit'])
        self.r.start_helper.assert_not_called(); self.core.execute.assert_not_called()
        for path in self.r.phase.glob('*.json'): self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_durable_proofs_precede_native_deletion_and_helper_closes_before_update(self):
        order = []
        original = self.r.node.side_effect
        def node(action, **kwargs):
            if action == 'execute': self.assertTrue((self.r.phase / 'file-proofs.json').exists())
            return original(action, **kwargs)
        self.r.node.side_effect = node
        self.r.close_helper.side_effect = lambda: order.append('close')
        self.core.execute.side_effect = lambda *args, **kwargs: order.append('deploy' if args[0].execute_approved else 'preflight')
        self.run_operator()
        self.assertEqual(order, ['close', 'preflight', 'deploy'])
        self.assertTrue((self.r.phase / 'installation-report.json').exists())
        self.assertEqual(self.core.execute.call_args.kwargs['rollback'], False)

    def test_failed_native_handler_retains_tasks_and_never_deploys(self):
        self.result = {'completed': False, 'code': 'NATIVE_FILEDELETE_FAILED_JOB_RETAINED', 'preserved': 21}
        with self.assertRaisesRegex(self.core.Stop, 'NATIVE_FILEDELETE_FAILED'):
            self.run_operator()
        self.core.execute.assert_not_called(); self.r.close_helper.assert_not_called()
        self.assertTrue(list(self.r.phase.glob('deletion-report-*.json')))

    def test_unknown_original_intent_stops_before_helper_or_filesystem(self):
        old = self.r.node.side_effect
        self.r.node.side_effect = lambda action, **kw: self.core.need(False, 'OTHER_DELETION_JOB_REQUIRES_INTENT_REVIEW') if action == 'admit' else old(action, **kw)
        with self.assertRaises(self.core.Stop): self.run_operator()
        self.r.start_helper.assert_not_called(); self.core.execute.assert_not_called()

    def test_preservation_gate_failure_stops_deployment_after_physical_work(self):
        old = self.r.node.side_effect
        self.r.node.side_effect = lambda action, **kw: self.core.need(False, 'OTHER_JOBS_CHANGED_NO_DEPLOYMENT') if action == 'gate' else old(action, **kw)
        with self.assertRaises(self.core.Stop): self.run_operator()
        self.core.execute.assert_not_called()

    def test_changed_inventory_seal_is_rejected(self):
        self.run_operator(False)
        path = self.r.phase / 'queue-snapshot.json'; path.write_text(json.dumps({**self.snapshot, 'paused': False}))
        with self.assertRaisesRegex(self.core.Stop, 'SEALED_QUEUE_SNAPSHOT_CHANGED'): self.r.values()

    def test_helper_originals_are_ro_and_only_three_derivative_subdirectories_rw(self):
        # Restore the real method; no actual Docker command is executed.
        self.run_operator(False)
        self.r.start_helper = m.Runner.start_helper.__get__(self.r)
        self.r.handlers = Mock()
        current = {'Id': 'production-id', 'Image': self.r.hp.CURRENT, 'Config': {'Env': ['DB_PASSWORD=SYNTHETIC_PRIVATE', 'IMMICH_SOURCE_COMMIT=']},
                   'Mounts': [{'Destination': '/data', 'Source': '/fixture/media', 'Type': 'bind', 'RW': True}]}
        helper = {'Id': 'unique', 'Image': self.r.hp.TARGET, 'State': {'Running': True, 'StartedAt': 'fixed', 'Pid': 123},
                  'Config': {'Labels': {'gallery.confirmed-files.run': str(self.runroot)}},
                  'HostConfig': {'ReadonlyRootfs': True, 'Privileged': False, 'CapDrop': ['ALL'], 'CapAdd': ['FOWNER'],
                                 'Memory': 512*1024**2, 'NanoCpus': 500_000_000, 'NetworkMode': 'container:production-id'},
                  'Mounts': [{'Destination': '/data', 'RW': False}] +
                            [{'Destination': '/data/'+folder, 'RW': True} for folder in ('thumbs', 'encoded-video', 'profile')]}
        self.core.inspect.side_effect = lambda name: current if name == self.core.SERVER else helper
        self.core.docker = Mock(return_value='')
        calls = []
        def run(args, **kw):
            calls.append(args)
            if args[:3] == ['sudo', '-n', 'realpath']: return args[-1]
            if 'exec' in args: return json.dumps(self.snapshot['rootPhysical'])
            return 'unique'
        self.core.run.side_effect = run
        self.r.start_helper()
        command = next(c for c in calls if 'run' in c)
        self.assertEqual(command[command.index('--volumes-from')+1], 'immich_server:ro')
        self.assertEqual(command[command.index('--network')+1], 'container:immich_server')
        self.assertIn('--read-only', command); self.assertNotIn('--privileged', command)
        binds = [command[i+1] for i, value in enumerate(command) if value == '--mount']
        self.assertEqual(len(binds), 3)
        self.assertTrue(all('upload' not in bind and 'library' not in bind for bind in binds))
        self.assertEqual((self.r.phase/'native-handler.env').stat().st_mode & 0o777, 0o600)
        self.assertNotIn('IMMICH_SOURCE_COMMIT=', (self.r.phase/'native-handler.env').read_text())

    def test_helper_fingerprint_preserves_duplicate_mounts_and_ignores_order_only(self):
        item = {'Id': 'id', 'Image': 'image', 'State': {'StartedAt': 'fixed', 'Pid': 123},
                'Config': {}, 'HostConfig': {}, 'Mounts': [{'x': 1}, {'x': 2}]}
        a = self.r.helper_fingerprint(item)
        self.assertEqual(a, self.r.helper_fingerprint({**item, 'Mounts': list(reversed(item['Mounts']))}))
        self.assertNotEqual(a, self.r.helper_fingerprint({**item, 'Mounts': item['Mounts']+[{'x': 1}]}))
        self.assertNotEqual(a, self.r.helper_fingerprint({**item, 'State': {'StartedAt': 'changed', 'Pid': 999}}))


if __name__ == '__main__':
    unittest.main()
