"""Read-only fixtures for stacked systemd automounts; no real NAS/DB access."""
import io
import json
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'gallery-nas-recovery-565ef38.sh'
source = SCRIPT.read_text().split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
validator = types.ModuleType('nas_recovery_validator_test')
exec(compile(source, str(SCRIPT), 'exec'), validator.__dict__)


class MountLookupTests(unittest.TestCase):
    target = '/mnt/synology-homes'
    source = '10.10.10.95:/volume1/homes'

    def actual(self):
        return dict(target=self.target, source=self.source, fstype='nfs', options='ro')

    def wrapper(self):
        return dict(target=self.target, source='systemd-1', fstype='autofs', options='rw')

    def lookup(self, rows):
        with patch.object(validator, 'cmd', return_value=json.dumps({'filesystems': rows})) as command:
            result = validator.mount(Path(self.target))
        self.assertEqual(command.call_args.args[0], [
            'findmnt', '-J', '-T', self.target, '-o', 'TARGET,SOURCE,FSTYPE,OPTIONS'])
        return result

    def test_stacked_autofs_and_nfs_in_either_order(self):
        actual = self.actual()
        for rows in ([self.wrapper(), actual], [actual, self.wrapper()]):
            with self.subTest(rows=rows):
                self.assertEqual(self.lookup(rows), actual)

    def test_nested_autofs_child_nfs(self):
        actual = self.actual()
        wrapper = self.wrapper()
        wrapper['children'] = [actual]
        self.assertEqual(self.lookup([wrapper]), actual)

    def test_ordinary_nfs_and_nfs4(self):
        for filesystem in ('nfs', 'nfs4'):
            with self.subTest(filesystem=filesystem):
                actual = self.actual()
                actual['fstype'] = filesystem
                self.assertEqual(self.lookup([actual]), actual)

    def test_autofs_without_actual_filesystem_rejected(self):
        with self.assertRaisesRegex(validator.Stop, 'MOUNT_LOOKUP_AMBIGUOUS'):
            self.lookup([self.wrapper()])

    def test_empty_inventory_rejected(self):
        with self.assertRaisesRegex(validator.Stop, 'MOUNT_LOOKUP_AMBIGUOUS'):
            self.lookup([])

    def test_duplicate_actual_nfs_not_deduplicated(self):
        with self.assertRaisesRegex(validator.Stop, 'MOUNT_LOOKUP_AMBIGUOUS'):
            self.lookup([self.wrapper(), self.actual(), self.actual()])

    def test_actual_nfs_plus_shadowing_local_filesystem_rejected(self):
        shadow = dict(target=self.target, source='/dev/fixture', fstype='ext4', options='rw')
        with self.assertRaisesRegex(validator.Stop, 'MOUNT_LOOKUP_AMBIGUOUS'):
            self.lookup([self.wrapper(), self.actual(), shadow])

    def test_local_staging_filesystem_unchanged(self):
        local = dict(target='/', source='/dev/fixture', fstype='ext4', options='rw')
        self.assertEqual(self.lookup([local]), local)


class MountPreflightTests(unittest.TestCase):
    """Exercise the real main() guards, stopping before any snapshot operation."""

    def preflight(self, change=None, stacked=True):
        with tempfile.TemporaryDirectory(prefix='nas-mount-test-') as directory:
            base = Path(directory)
            old, state = base / 'previous', base / 'new'
            old.mkdir(mode=0o700)
            state.mkdir(mode=0o700)
            audit = base / 'audit.json'
            validator.save(old / 'recovery-report.txt', {'checks': {'POSTGRES_RESTORE': 'PASS'}})
            validator.save(old / 'backup-verified.json', {
                'restore': 'PASS_ISOLATED_SQL_TRANSACTION', 'productionChanged': False})
            validator.save(audit, {
                'backendReadOnlyAudit': {'errors': [], 'sections': {str(i): 'PASS' for i in range(10)}},
                'containers': [{'role': 'immich_server', 'externalMounts': [
                    {'containerMountpoint': '/external/' + label, 'hostMountpoint': path}
                    for label, (path, _) in validator.ROOTS.items()]}]})
            previous_hashes = {path: validator.sha(path) for path in (*old.iterdir(), audit)}
            answers = iter([str(old), str(audit)])

            def findmnt(args):
                self.assertEqual(args[:3], ['findmnt', '-J', '-T'])
                target = args[3]
                if target == str(state):
                    rows = [dict(target='/', source='/dev/fixture', fstype='ext4', options='rw')]
                else:
                    label = next(k for k, v in validator.ROOTS.items() if v[0] == target)
                    export = validator.ROOTS[label][1]
                    actual = dict(target=target, source='10.10.10.95:' + export,
                                  fstype='nfs4', options='ro' if label == 'homes' else 'rw')
                    rows = ([dict(target=target, source='systemd-1', fstype='autofs', options='rw')]
                            if stacked else []) + [actual]
                    if change:
                        rows = change(label, rows)
                return json.dumps({'filesystems': rows})

            with patch.object(validator.pwd, 'getpwuid', return_value=types.SimpleNamespace(pw_name='doctoriceadm')), \
                 patch.object(validator.tempfile, 'mkdtemp', return_value=str(state)), \
                 patch.object(validator, 'ask', side_effect=lambda _: next(answers)), \
                 patch.object(validator, 'cmd', side_effect=findmnt), \
                 patch.object(validator, 'get_tool', side_effect=validator.Stop('MOUNT_CHECKS_PASSED_TEST_STOP')) as gate, \
                 patch('sys.stdout', new_callable=io.StringIO):
                self.assertEqual(validator.main(), 1)  # Fixture intentionally stops before recovery.
            report = validator.load(state / 'nas-recovery-report.txt')
            self.assertEqual(report['checks']['POSTGRES_RESTORE'], 'PASS_REUSED_NO_RESTORE')
            self.assertEqual(report['checks']['PREVIOUS_EVIDENCE'], 'PASS_UNCHANGED')
            self.assertEqual(report['result'], 'FAIL')
            self.assertFalse((state / 'nas-verified.json').exists())
            self.assertEqual({path: validator.sha(path) for path in previous_hashes}, previous_hashes)
            return report['blockers'], gate.call_count

    def test_all_expected_stacked_mounts_pass_exact_mapping_guards(self):
        blockers, calls = self.preflight()
        self.assertEqual(blockers, ['MOUNT_CHECKS_PASSED_TEST_STOP'])
        self.assertEqual(calls, 1)

    def test_all_expected_ordinary_nfs_mounts_pass(self):
        blockers, calls = self.preflight(stacked=False)
        self.assertEqual(blockers, ['MOUNT_CHECKS_PASSED_TEST_STOP'])
        self.assertEqual(calls, 1)

    def test_missing_nfs_for_each_expected_target_rejected(self):
        for label in validator.ROOTS:
            with self.subTest(label=label):
                blockers, calls = self.preflight(lambda k, rows: rows[:-1] if k == label else rows)
                self.assertEqual(blockers, ['MOUNT_LOOKUP_AMBIGUOUS'])
                self.assertEqual(calls, 0)

    def test_wrong_nfs_source_for_each_expected_target_rejected(self):
        for label in validator.ROOTS:
            with self.subTest(label=label):
                def change(k, rows):
                    if k == label:
                        rows[-1]['source'] = '10.10.10.96:/volume1/wrong'
                    return rows
                blockers, calls = self.preflight(change)
                self.assertEqual(blockers, ['LIVE_NFS_MAPPING_MISMATCH_' + label])
                self.assertEqual(calls, 0)

    def test_wrong_nfs_target_for_each_expected_source_rejected(self):
        for label in validator.ROOTS:
            with self.subTest(label=label):
                def change(k, rows):
                    if k == label:
                        rows[-1]['target'] += '-wrong'
                    return rows
                blockers, calls = self.preflight(change)
                self.assertEqual(blockers, ['LIVE_NFS_MAPPING_MISMATCH_' + label])
                self.assertEqual(calls, 0)

    def test_one_correct_and_one_wrong_nfs_never_picks_correct_one(self):
        def change(label, rows):
            return rows + [dict(rows[-1], source='10.10.10.96:/wrong')]
        blockers, calls = self.preflight(change)
        self.assertEqual(blockers, ['MOUNT_LOOKUP_AMBIGUOUS'])
        self.assertEqual(calls, 0)

    def test_non_nfs_actual_mount_rejected(self):
        def change(label, rows):
            rows[-1]['fstype'] = 'ext4'
            return rows
        blockers, calls = self.preflight(change)
        self.assertEqual(blockers, ['LIVE_NFS_MAPPING_MISMATCH_docice'])
        self.assertEqual(calls, 0)

    def test_homes_read_only_requirement_preserved(self):
        def change(label, rows):
            if label == 'homes':
                rows[-1]['options'] = 'rw'
            return rows
        blockers, calls = self.preflight(change)
        self.assertEqual(blockers, ['HOMES_PARENT_NOT_READ_ONLY'])
        self.assertEqual(calls, 0)


if __name__ == '__main__':
    unittest.main()
