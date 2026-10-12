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
    def complete_helper(self, helper, current):
        helper.update(Name='/'+self.r.helper, Path='node', Args=['-e', 'setInterval(()=>{},10000)'])
        helper['Config'].update(Entrypoint=['node'], Cmd=['-e', 'setInterval(()=>{},10000)'])
        helper['HostConfig'].update(Privileged=False, PidsLimit=128, SecurityOpt=['no-new-privileges'],
                                  PidMode='', IpcMode='private', UTSMode='', UsernsMode='')
        for row in helper['Mounts']:
            original = next((r for r in current['Mounts'] if r['Destination'] == row['Destination']), None)
            row.update(Type='bind', Source=original['Source'] if original else '/fixture/media'+row['Destination'][5:])
            if row['RW']: row['Propagation'] = 'rprivate'
        return helper

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='gallery-queued-release-test-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.runroot = self.root / 'gallery-build10-release-TxDlXAuj'; self.runroot.mkdir(mode=0o700)
        self.r = m.Runner(self.runroot)
        self.r.phase.mkdir(mode=0o700)
        self.state = self.runroot / 'hardened-rollback/image-state'; self.state.mkdir(mode=0o700, parents=True)
        self.snapshot = {'paused': True, 'counts': {'paused': 27}, 'mediaRoot': '/data', 'knownBackgroundJobs': ['FileDelete', 'MemoryGenerate'],
                         'jobs': [{'id': id, 'name': 'FileDelete', 'hash': id, 'data': {'files': ['/data/'+
                                  ('thumbs', 'encoded-video', 'profile')[i % 3]+'/fixture-'+id]}} for i, id in enumerate(m.IDS)] +
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
        self.intent = {'contract': 'confirmed-native-cleanup-v1', 'rootPhysical': self.snapshot['rootPhysical'],
                       'files': [{'root': r['path']} for r in self.snapshot['rootPhysical']]}
        self.r.producer_contract = Mock(return_value={'image': self.r.hp.CURRENT, 'nativeProducerSHA256': 'a'*64})
        self.actions = []
        def node(action, **kwargs):
            self.actions.append(action)
            if action == 'inventory': return self.snapshot
            if action == 'admit': return {'passed': True}
            if action == 'intent': return {**self.intent, 'snapshotSeal': self.r.values()['snapshotSeal']}
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
        self.run_operator()
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
        self.complete_helper(helper, current)
        self.core.inspect.side_effect = lambda name: current if name == self.core.SERVER else helper
        self.core.docker = Mock(return_value='')
        calls = []
        def run(args, **kw):
            calls.append(args)
            if args[:3] == ['sudo', '-n', 'realpath']: return args[-1]+'\n'
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

    def test_confirmed_upload_scope_is_narrow_and_other_owners_libraries_stay_read_only(self):
        owner = '11111111-1111-4111-8111-111111111111'
        scope = '/data/upload/' + owner
        for job in self.snapshot['jobs'][:6]: job['data']['temporaryOwnerId'] = owner
        self.intent = {'contract': 'confirmed-native-cleanup-v1', 'rootPhysical': [{
            'path': scope, 'device': '1', 'inode': '99', 'uid': '1024', 'gid': '100'}], 'files': [{'root': scope}]}
        self.run_operator()
        self.r.producer_contract.assert_called_once()
        self.r.start_helper = m.Runner.start_helper.__get__(self.r)
        self.r.handlers = Mock()
        current = {'Id': 'prod', 'Image': self.r.hp.CURRENT, 'Config': {'Env': []}, 'Mounts': [
            {'Destination': '/data', 'Source': '/fixture/media', 'Type': 'bind', 'RW': True},
            {'Destination': '/external', 'Source': '/fixture/nas', 'Type': 'bind', 'RW': True}]}
        helper = {'Id': 'helper', 'Image': self.r.hp.TARGET, 'State': {'Running': True, 'StartedAt': 'fixed', 'Pid': 123},
                  'Config': {'Labels': {'gallery.confirmed-files.run': str(self.runroot)}},
                  'HostConfig': {'ReadonlyRootfs': True, 'CapDrop': ['ALL'], 'CapAdd': ['FOWNER'],
                                 'Memory': 512*1024**2, 'NanoCpus': 500_000_000, 'NetworkMode': 'container:prod'},
                  'Mounts': [{'Destination': '/data', 'RW': False}, {'Destination': '/external', 'RW': False},
                             {'Destination': scope, 'RW': True}]}
        self.complete_helper(helper, current)
        self.core.inspect.side_effect = lambda name: current if name == self.core.SERVER else helper
        self.core.docker = Mock(return_value='')
        calls = []
        def run(args, **kw):
            calls.append(args)
            if args[:3] == ['sudo', '-n', 'realpath']: return args[-1]+'\n'
            if 'exec' in args: return json.dumps(self.intent['rootPhysical'])
            return 'helper'
        self.core.run.side_effect = run
        self.r.start_helper()
        command = next(c for c in calls if 'run' in c)
        mounts = [command[i+1] for i, value in enumerate(command) if value == '--mount']
        self.assertEqual(mounts, ['type=bind,src=/fixture/media/upload/'+owner+',dst='+scope])
        self.assertEqual({mount.split(',dst=')[1] for mount in mounts}, {scope})

    def test_unproven_intent_stops_before_helper_and_deployment(self):
        old = self.r.node.side_effect
        self.r.node.side_effect = lambda action, **kw: self.core.need(False, 'LEGACY_ORIGINAL_REQUIRES_ASSET_DELETION_INTENT') if action == 'intent' else old(action, **kw)
        with self.assertRaisesRegex(self.core.Stop, 'LEGACY_ORIGINAL_REQUIRES'): self.run_operator()
        self.r.start_helper.assert_not_called(); self.core.execute.assert_not_called()

    def test_cached_intent_tampering_is_rejected(self):
        self.run_operator()
        path = self.r.phase/'cleanup-intent-v1.json'
        data = self.core.private_json(path); data['rootPhysical'][0]['inode'] = 'changed'
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(self.core.Stop, 'SEALED_CLEANUP_INTENT_CHANGED'): self.r.intent_values()

    def test_native_cleanup_producer_mismatch_rejected_without_new_authorization(self):
        self.r.producer_contract = m.Runner.producer_contract.__get__(self.r)
        self.core.run.side_effect = ['a'*64, 'b'*64]
        with self.assertRaisesRegex(self.core.Stop, 'LEGACY_UPLOAD_PRODUCER_DIFFERS'): self.r.producer_contract()
        self.assertFalse((self.r.phase/'native-cleanup-producer-v1.json').exists())

    def test_native_producer_hash_stdout_newline_is_not_a_contract_change(self):
        self.r.producer_contract = m.Runner.producer_contract.__get__(self.r)
        self.core.run.side_effect = ['a'*64+'\n', 'a'*64+'\n']
        self.assertEqual(self.r.producer_contract()['nativeProducerSHA256'], 'a'*64)

    def test_helper_fingerprint_preserves_duplicate_mounts_and_ignores_order_only(self):
        item = {'Id': 'id', 'Image': 'image', 'State': {'StartedAt': 'fixed', 'Pid': 123},
                'Config': {}, 'HostConfig': {}, 'Mounts': [{'x': 1}, {'x': 2}]}
        a = self.r.helper_fingerprint(item)
        self.assertEqual(a, self.r.helper_fingerprint({**item, 'Mounts': list(reversed(item['Mounts']))}))
        self.assertNotEqual(a, self.r.helper_fingerprint({**item, 'Mounts': item['Mounts']+[{'x': 1}]}))
        self.assertNotEqual(a, self.r.helper_fingerprint({**item, 'State': {'StartedAt': 'changed', 'Pid': 999}}))


class PrivateCommandDiagnostics(unittest.TestCase):
    def setUp(self):
        self.core = m.load('image_release')

    def test_subprocess_failure_reports_only_fixed_stage_and_verb(self):
        args = ['sudo', '-n', 'docker', '--host=unix:///var/run/docker.sock', 'run',
                '--env', 'PRIVATE_TOKEN=synthetic', 'private-image', 'exec']
        run = Mock(side_effect=self.core.Stop('COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED'))
        with self.assertRaisesRegex(self.core.Stop, '^HANDLER_HASH_VERIFICATION_DOCKER_RUN_FAILED$') as error:
            m.checked_command(self.core, run, 'HANDLER_HASH_VERIFICATION', args, timeout=30)
        self.assertNotIn('PRIVATE_TOKEN', str(error.exception))
        self.assertNotIn('private-image', str(error.exception))
        run.assert_called_once_with(args, timeout=30)

    def test_existing_safety_stop_is_preserved(self):
        stop = self.core.Stop('SCOPED_HELPER_CAPABILITIES_REQUIRED')
        with self.assertRaises(self.core.Stop) as error:
            m.checked_command(self.core, Mock(side_effect=stop), 'IMAGE_UPDATE', ['docker', 'inspect'])
        self.assertIs(error.exception, stop)

    def test_success_output_and_arguments_are_unchanged(self):
        run = Mock(return_value='private captured stdout')
        self.assertEqual(m.checked_command(self.core, run, 'NATIVE_REQUEST', ['docker', 'exec'], input='private'),
                         'private captured stdout')
        run.assert_called_once_with(['docker', 'exec'], input='private')

    def test_operation_classifier_does_not_scan_private_arguments(self):
        self.assertEqual(m.command_kind(['docker', '--host=unix:///var/run/docker.sock', 'run', 'exec']), 'DOCKER_RUN')
        self.assertEqual(m.command_kind(['sudo', '-n', 'realpath', '-e', '/private']), 'HOST_MAPPING')
        self.assertEqual(m.command_kind(['bash', '/private/docker', 'exec']), 'PRIVATE_SUBPROCESS')
        self.assertEqual(m.command_kind(['bash', '/private/prepare.sh', 'docker', 'exec']), 'PRIVATE_SUBPROCESS')
        self.assertEqual(m.command_kind(['docker', '--unknown', 'exec']), 'PRIVATE_SUBPROCESS')

    def test_nested_native_request_restores_image_update_stage_even_after_failure(self):
        runner = SimpleNamespace(command_stage='IMAGE_UPDATE')
        @m.command_stage('NATIVE_REQUEST')
        def gate(value):
            self.assertEqual(value.command_stage, 'NATIVE_REQUEST')
            raise self.core.Stop('OTHER_JOBS_CHANGED_NO_DEPLOYMENT')
        with self.assertRaises(self.core.Stop): gate(runner)
        self.assertEqual(runner.command_stage, 'IMAGE_UPDATE')


class SecurityProfile(unittest.TestCase):
    def setUp(self):
        self.core = m.load('image_release')
        self.current = {'Id': 'pinned-production-id'}
        self.host = {'ReadonlyRootfs': True, 'Privileged': False, 'CapDrop': ['ALL'], 'CapAdd': ['CAP_FOWNER'],
                     'Memory': 512*1024**2, 'NanoCpus': 500_000_000, 'PidsLimit': 128,
                     'SecurityOpt': ['no-new-privileges'], 'PidMode': '', 'IpcMode': 'private', 'UTSMode': '',
                     'UsernsMode': '', 'NetworkMode': 'container:pinned-production-id'}

    def test_docker_cap_prefix_is_semantically_identical_but_not_extra_permission(self):
        for value in ('FOWNER', 'CAP_FOWNER'):
            with self.subTest(value=value):
                m.security_profile(self.core, {'HostConfig': {**self.host, 'CapAdd': [value]}}, self.current)

    def test_rejects_extra_duplicate_or_malformed_capability(self):
        for added in (['CAP_SYS_ADMIN'], ['FOWNER', 'SYS_ADMIN'], ['FOWNER', 'CAP_FOWNER'],
                      ['CAP_CAP_FOWNER'], [], None, ['CAP_fowner']):
            with self.subTest(added=added), self.assertRaisesRegex(self.core.Stop, 'CAPABILITIES'):
                m.security_profile(self.core, {'HostConfig': {**self.host, 'CapAdd': added}}, self.current)

    def test_rejects_every_unsafe_profile_dimension(self):
        changes = [dict(ReadonlyRootfs=False), dict(Privileged=True), dict(CapDrop=[]),
                   dict(Memory=0), dict(NanoCpus=0), dict(PidsLimit=-1), dict(SecurityOpt=[]),
                   dict(SecurityOpt=['no-new-privileges', 'seccomp=unconfined']), dict(PidMode='host'),
                   dict(IpcMode='host'), dict(UTSMode='host'), dict(UsernsMode='host'),
                   dict(Devices=[{'PathOnHost': '/dev/dri/renderD128'}]), dict(DeviceRequests=[{}]),
                   dict(PortBindings={'80/tcp': [{}]}), dict(NetworkMode='host'),
                   dict(NetworkMode='container:another-id')]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(self.core.Stop):
                m.security_profile(self.core, {'HostConfig': {**self.host, **change}}, self.current)


class EarlyStopRecovery(unittest.TestCase):
    # Reuse setup/helpers, not Fixture's test methods.
    complete_helper = Fixture.complete_helper
    run_operator = Fixture.run_operator

    def setUp(self):
        Fixture.setUp(self)
        self.run_operator(False)
        intent = {**self.intent, 'snapshotSeal': self.r.values()['snapshotSeal']}
        self.core.save(self.r.phase/'cleanup-intent-v1.json', intent)
        self.core.save(self.r.phase/'cleanup-intent-seal-v1.json', {'sha256': hashlib.sha256(
            json.dumps(intent, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()})
        self.core.save(self.r.phase/'stop-fixture.json', {'code': 'SCOPED_HELPER_SECURITY_PROFILE_REQUIRED'})
        self.current = {'Id': 'prod', 'Image': self.r.hp.CURRENT, 'Config': {'Env': ['FIXTURE_PRIVATE=synthetic']},
                        'Mounts': [{'Type': 'bind', 'Source': '/fixture/media', 'Destination': '/data', 'RW': True}]}
        self.helper = self.complete_helper({
            'Id': 'verified-helper', 'Image': self.r.hp.TARGET,
            'State': {'Running': True, 'StartedAt': 'fixed', 'Pid': 123},
            'Config': {'Labels': {'gallery.confirmed-files.run': str(self.runroot)},
                       'Env': ['BAKED=source', 'FIXTURE_PRIVATE=synthetic'], 'User': '', 'WorkingDir': '/app'},
            'HostConfig': {'ReadonlyRootfs': True, 'CapDrop': ['ALL'], 'CapAdd': ['CAP_FOWNER'],
                           'Memory': 512*1024**2, 'NanoCpus': 500_000_000, 'NetworkMode': 'container:prod'},
            'Mounts': [{'Destination': '/data', 'RW': False}]+[{'Destination': r['path'], 'RW': True}
                      for r in intent['rootPhysical']],
        }, self.current)
        self.core.inspect.side_effect = lambda name: self.current if name == self.core.SERVER else self.helper
        self.core.image = Mock(return_value={'Config': {'Env': ['BAKED=source'], 'User': '', 'WorkingDir': '/app'}})
        self.r.handlers = Mock()
        self.kernel = {'CapEff': '0000000000000008', 'CapPrm': '0000000000000008', 'CapBnd': '0000000000000008',
                       'CapInh': '0000000000000000', 'CapAmb': '0000000000000000', 'NoNewPrivs': '1', 'Seccomp': '2'}
        def run(args, **kwargs):
            if args[:3] == ['sudo', '-n', 'realpath']: return args[-1]+'\n'
            if '/proc/1/status' in args[-1]: return json.dumps(self.kernel)
            if 'exec' in args: return json.dumps(intent['rootPhysical'])
            self.fail('Unexpected Docker mutation during early recovery')
        self.core.run.side_effect = run
        (self.r.phase/'native-handler.env').write_text('FIXTURE_PRIVATE=synthetic\n')
        (self.r.phase/'native-handler.env').chmod(0o600)

    def test_revalidates_existing_helper_without_recreation_or_deletion(self):
        with redirect_stdout(io.StringIO()): self.r.recover_unsealed_helper(self.helper, self.current)
        self.assertTrue((self.r.phase/'native-handler.json').exists())
        self.assertEqual(self.core.private_json(self.r.phase/'native-handler.json'), self.r.helper_fingerprint(self.helper))
        self.assertTrue(list(self.r.phase.glob('helper-recovery-*.json')))
        self.r.helper_binding(self.helper)
        self.assertFalse((self.r.phase/'file-proofs.json').exists())
        self.core.execute.assert_not_called()

    def test_any_possible_prior_file_operation_blocks_adoption(self):
        self.core.save(self.r.phase/'file-proofs.json', {'fixture': 'must preserve'})
        with self.assertRaisesRegex(self.core.Stop, 'AFTER_FILE_WORK_FORBIDDEN'):
            self.r.recover_unsealed_helper(self.helper, self.current)
        self.assertFalse((self.r.phase/'native-handler.json').exists())

    def test_missing_original_stop_receipt_blocks_adoption(self):
        (self.r.phase/'stop-fixture.json').write_text(json.dumps({'code': 'SOME_OTHER_STOP'}))
        with self.assertRaisesRegex(self.core.Stop, 'EARLY_HELPER_STOP_REQUIRED'):
            self.r.recover_unsealed_helper(self.helper, self.current)

    def test_changed_queue_or_root_intent_blocks_adoption(self):
        old = self.r.node.side_effect
        self.r.node.side_effect = lambda action, **kwargs: {'changed': True} if action == 'intent' else old(action, **kwargs)
        with self.assertRaisesRegex(self.core.Stop, 'INTENT_CHANGED'):
            self.r.recover_unsealed_helper(self.helper, self.current)

    def test_changed_host_binding_blocks_adoption(self):
        self.helper['Mounts'][1]['Source'] = '/another/owner'
        with self.assertRaisesRegex(self.core.Stop, 'WRITABLE_BIND_CHANGED'):
            self.r.recover_unsealed_helper(self.helper, self.current)

    def test_changed_env_or_kernel_sandbox_blocks_adoption(self):
        for change in ('env', 'capabilities', 'privileges', 'seccomp'):
            with self.subTest(change=change):
                before = self.helper['Config']['Env'][:]; saved = self.kernel.copy()
                if change == 'env': self.helper['Config']['Env'].append('INJECTED=not-permitted')
                if change == 'capabilities': self.kernel['CapEff'] = '0000000000200008'
                if change == 'privileges': self.kernel['NoNewPrivs'] = '0'
                if change == 'seccomp': self.kernel['Seccomp'] = '0'
                with self.assertRaises(self.core.Stop): self.r.recover_unsealed_helper(self.helper, self.current)
                self.helper['Config']['Env'] = before; self.kernel = saved
                self.assertFalse((self.r.phase/'native-handler.json').exists())


if __name__ == '__main__':
    unittest.main()
