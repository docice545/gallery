import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

RELEASE = Path(__file__).parents[1]
sys.path.insert(0, str(RELEASE))
SPEC = importlib.util.spec_from_file_location('build11_restore_test', RELEASE / 'build11_restore_transition.py')
transition = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transition)
SOURCE = 'a' * 40
IMAGE = 'sha256:' + 'b' * 64
ROLLBACK = 'sha256:' + 'c' * 64
CONTAINER = 'gallery-restore-check-1234567890abcdef'


def fixture():
    return {'State': {'Running': True}, 'HostConfig': {'NetworkMode': 'none', 'Binds': [], 'VolumesFrom': [], 'PortBindings': {}, 'Privileged': False},
            'Mounts': [{'Type': 'volume', 'Name': 'f' * 64}]}


class RestoreTransition(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.state = Path(temporary.name)
        self.backup = self.state / 'synthetic.sql.gz'
        self.backup.write_bytes(b'synthetic backup checksum only; mock test')
        self.before = {'assetCount': 3, 'libraryCount': 1, 'statusCounts': {'active': 2, 'trashed': 1}, 'migrationNames': ['build10'], 'orphans': 0}
        self.after = {**self.before, 'migrationNames': sorted(['build10', transition.MIGRATION])}
        self.query = ['exec', CONTAINER, 'psql', '-X', '-q', '-A', '-t', '-c', 'BEGIN READ ONLY', '-c', 'SELECT synthetic', '-c', 'COMMIT']
        self.fingerprints = {table: {'count': 2, 'sha256': 'd' * 64} for table in transition.TABLES}
        self.tool = SimpleNamespace(BUILD11_SOURCE=SOURCE, inspect=Mock(return_value=fixture()))
        self.responses = [json.dumps([{'Id': IMAGE, 'Config': {'Env': ['IMMICH_SOURCE_COMMIT=' + SOURCE]}}]),
                          json.dumps(self.fingerprints), '', json.dumps(self.after), json.dumps(self.fingerprints),
                          '', json.dumps(self.after), json.dumps(self.fingerprints), json.dumps({'recovery': 2, 'storage': 0})]

    def execute(self, responses=None):
        docker = Mock(side_effect=responses or self.responses)
        report = transition.build11_restore_transition(self.tool, docker, CONTAINER, self.query, self.before,
                                                      self.state, self.backup, IMAGE, ROLLBACK)
        return report, docker

    def test_preserves_nonzero_existing_policies_and_distinguishes_migrations_from_actual_api_acceptance(self):
        report, docker = self.execute()
        self.assertTrue(report['policiesPreserved'])
        self.assertEqual(report['legacyPolicyCount'], 2)
        self.assertFalse(report['oldRuntimeStartsOnUpgradedSchema'])
        self.assertFalse(report['trashRestoreAfterRollback'])
        self.assertEqual(report['runtimeRollbackAcceptance'], 'NOT TESTED')
        self.assertFalse(report['productionChanged'])
        self.assertEqual(len([call for call in docker.call_args_list if call.args[0] == 'run']), 2)
        for call in docker.call_args_list:
            if call.args[0] == 'run':
                self.assertIn('container:' + CONTAINER, call.args)
                self.assertIn('--read-only', call.args)
                self.assertNotIn('--mount', call.args)
                self.assertNotIn('-p', call.args)

    def test_root_mount_ports_network_and_named_production_volume_are_rejected(self):
        for change in ({'NetworkMode': 'bridge'}, {'Binds': ['/mnt/family:/data']}, {'PortBindings': {'5432': []}}, {'Privileged': True}):
            value = fixture()
            value['HostConfig'].update(change)
            with self.subTest(change=change), self.assertRaisesRegex(RuntimeError, 'NO_PRODUCTION_NETWORK_OR_MOUNTS'):
                transition.isolated_fixture(value, CONTAINER)
        value = fixture()
        value['Mounts'][0]['Name'] = 'immich-production-data'
        with self.assertRaisesRegex(RuntimeError, 'NO_PRODUCTION_NETWORK_OR_MOUNTS'):
            transition.isolated_fixture(value, CONTAINER)

    def test_real_looking_production_name_is_rejected_even_with_network_none(self):
        with self.assertRaisesRegex(RuntimeError, 'ISOLATED_RESTORE_NAME_REQUIRED'):
            transition.isolated_fixture(fixture(), 'immich_postgres')

    def test_row_metadata_change_cannot_be_hidden_by_equal_counts(self):
        changed = {**self.fingerprints, 'asset': {'count': 2, 'sha256': 'e' * 64}}
        self.responses[4] = json.dumps(changed)
        with self.assertRaisesRegex(RuntimeError, 'CHANGED_EXISTING_ROWS'):
            self.execute()
        self.assertFalse((self.state / 'build11-restored-database-verified.json').exists())

    def test_extra_migration_or_asset_count_change_blocks_upgrade(self):
        for after in ({**self.after, 'migrationNames': [*self.after['migrationNames'], 'unexpected']}, {**self.after, 'assetCount': 4, 'statusCounts': {'active': 3, 'trashed': 1}}):
            responses = self.responses.copy()
            responses[3] = json.dumps(after)
            with self.subTest(after=after), self.assertRaisesRegex(RuntimeError, 'CHANGED_DATABASE'):
                self.execute(responses)

    def test_implicit_storage_grant_is_rejected(self):
        self.responses[-1] = json.dumps({'recovery': 1, 'storage': 1})
        with self.assertRaisesRegex(RuntimeError, 'IMPLICIT_STORAGE_GRANT'):
            self.execute()

    def test_read_query_replaces_all_commands_and_enforces_read_only(self):
        query = transition.read_query(self.query, 'SELECT count(*) FROM asset')
        self.assertNotIn('SELECT synthetic', query)
        self.assertIn('BEGIN READ ONLY', query)
        self.assertEqual(query[-1], 'COMMIT')
        self.assertEqual(query.count('-c'), 4)

    def test_mutable_image_is_rejected_before_container_commands(self):
        docker = Mock()
        with self.assertRaisesRegex(RuntimeError, 'IMMUTABLE_IMAGE_ID_REQUIRED'):
            transition.build11_restore_transition(self.tool, docker, CONTAINER, self.query, self.before,
                                                  self.state, self.backup, 'gallery-server:latest', ROLLBACK)
        docker.assert_not_called()


if __name__ == '__main__':
    unittest.main()
